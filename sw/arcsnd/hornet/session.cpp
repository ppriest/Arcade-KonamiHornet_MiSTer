// SPDX-License-Identifier: GPL-3.0-or-later
// The Hornet sound board's session: runs while a Hornet set is loaded, against the block
// rtl/mister/hornet_sndbridge.sv shares in DDR3 (its header has the layout).
//
// The board starts when the bridge's magic is there and its beat moves: the 68000 program and the
// samples are copied from where the bridge says the fast load put them, the board starts from
// power-on with the bridge's current SNDRES and host registers, and the ring is taken from its
// current count. Each entry (a PPC write to a K056800 register or to SNDRES) is applied at its
// microsecond stamp mapped onto the board's clock LAT later, never closer to the one before than
// the stamps were (a command's five writes, and two commands 90 us apart, keep their spacing). The
// board runs a millisecond at a time, ahead of the audio by audio_out's lead, and publishes its two
// reply registers and a heartbeat after each. It stops (silence, the board freed) when the beat
// stalls for 200 ms (the core reloaded or held in reset), the magic goes, or the core changes.

#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

#include "board.h"
#include "daemon.h"

namespace {

using namespace arcsnd;

constexpr uint32_t SHM = 0x3F200000, SHM_SIZE = 0x2000;
constexpr uint32_t OFF_MAGIC = 0x00, OFF_ROMS = 0x08, OFF_COUNT = 0x10, OFF_BEAT = 0x18, OFF_STATE = 0x20,
                   OFF_STATUS = 0x40, OFF_RING = 0x1000;
constexpr uint32_t RING = 512;
constexpr uint32_t PROG_BYTES = 0x80000;
constexpr s64 TICKS_PER_MS = hornet_board::CPU_HZ / 1000;
constexpr s64 LAT = 2 * TICKS_PER_MS;             // an entry's delay past its stamp
// the sets, and the size of their sample region (the RF5C400's reads wrap at it)
struct set_info { const char *name; uint32_t samples; };
const set_info SETS[] = {
	{"gradius4", 0x800000}, {"gradius4u", 0x800000}, {"gradius4a", 0x800000}, {"gradius4ja", 0x800000},
	{"gradius4ua", 0x800000}, {"gradius4aa", 0x800000},
	{"nbapbp", 0x1000000}, {"nbapbpa", 0x1000000}, {"nbapbpj", 0x1000000}, {"nbapbpua", 0x1000000},
	{"nbapbpaa", 0x1000000}, {"nbapbpja", 0x1000000}, {"nbaatw", 0x1000000}, {"nbaatwa", 0x1000000},
};

uint32_t sample_bytes(const char *name)
{
	for (const set_info &s : SETS)
		if (!strcmp(name, s.name)) return s.samples;
	return 0;
}

}  // namespace

bool hornet_claims(const char *name)
{
	return sample_bytes(name) != 0;
}

// runs until the core changes or the process is stopped; mem is /dev/mem
void hornet_run(int mem, bool verbose)
{
	void *p = map(mem, SHM, SHM_SIZE);
	if (!p) { perror("mmap hornet block"); sleep_ns(1'000'000'000); return; }
	shared sh{static_cast<volatile uint32_t *>(p)};

	std::vector<u8> prog, samples;
	std::unique_ptr<hornet_board> board;
	audio_out audio;
	resampler rs;
	std::vector<int16_t> pcm;
	bool running = false;
	uint16_t heartbeat = 0;
	uint32_t beat_seen = 0, rd = 0;
	int64_t beat_t = now_ns();
	bool mapped = false;
	s64 offset = 0, last_tick = 0;
	uint32_t last_us = 0;
	core_name cname = read_core_name();
	const uint32_t SMP_BYTES = sample_bytes(cname.name.c_str());
	int64_t name_t = now_ns();
	int64_t rep_t = now_ns(), busy_ns = 0, rep_cpu = cpu_ns();
	uint32_t rep_entries = 0;

	auto publish = [&] {
		uint32_t lo = 0;
		if (running) lo = board->host_r(0) | uint32_t(board->host_r(1)) << 8;
		sh.write32(OFF_STATUS, lo);
		sh.write32(OFF_STATUS + 4, uint32_t(heartbeat++) << 16 | 0xA500u | (running ? 1u : 0u));
	};
	auto stop = [&](const char *why) {
		if (!running) return;
		running = false;
		board.reset();
		std::vector<u8>().swap(prog);
		std::vector<u8>().swap(samples);
		audio.fade();
		audio.close_dev();
		if (verbose) fprintf(stderr, "arcsnd hornet: %s\n", why);
	};
	auto apply = [&](uint64_t e) {
		const int reg = int((e >> 32) & 0xf);
		const u8 data = u8(e >> 40);
		if (reg == 8) board->sndres_w(data & 0x80);
		else board->host_w(reg, data);
		rep_entries++;
	};

	while (!g_stop)
	{
		if (now_ns() - name_t >= 250'000'000)
		{
			name_t = now_ns();
			const core_name c = read_core_name();
			if (c.written != cname.written || !hornet_claims(c.name.c_str())) break;
		}
		const uint64_t magic = sh.read64(OFF_MAGIC);
		if (uint32_t(magic) != 0x534E5248u)               // "HRNS"
		{
			stop("the bridge's magic is gone");
			sleep_ns(100'000'000);
			continue;
		}
		const uint32_t b = uint32_t(sh.read64(OFF_BEAT));
		if (b != beat_seen) { beat_seen = b; beat_t = now_ns(); }
		else if (now_ns() - beat_t >= 200'000'000)
		{
			stop("the core stopped");
			sleep_ns(20'000'000);
			continue;
		}

		if (!running)
		{
			const uint64_t roms = sh.read64(OFF_ROMS);
			const uint32_t pa = uint32_t(roms), sa = uint32_t(roms >> 32);
			prog.assign(PROG_BYTES, 0);
			samples.assign(SMP_BYTES, 0);
			void *pp = map(mem, pa, PROG_BYTES), *sp = map(mem, sa, SMP_BYTES);
			if (!pp || !sp)
			{
				perror("mmap hornet ROMs");
				unmap(pp, PROG_BYTES); unmap(sp, SMP_BYTES);
				sleep_ns(1'000'000'000);
				continue;
			}
			copy_in(prog.data(), static_cast<const volatile uint8_t *>(pp), PROG_BYTES);
			copy_in(samples.data(), static_cast<const volatile uint8_t *>(sp), SMP_BYTES);
			unmap(pp, PROG_BYTES); unmap(sp, SMP_BYTES);
			board = std::make_unique<hornet_board>(prog.data(), samples.data(), SMP_BYTES);
			const uint64_t st = sh.read64(OFF_STATE);
			for (int r = 0; r < 4; r++) board->host_w(r, u8(st >> (8 * r)));
			board->sndres_w((st >> 32) & 1);
			rd = uint32_t(sh.read64(OFF_COUNT));
			mapped = false;
			rs = resampler{};
			audio.open_dev();
			running = true;
			if (verbose) fprintf(stderr, "arcsnd hornet: started (program at %08x, samples at %08x, SNDRES %d)\n",
			                     pa, sa, int((st >> 32) & 1));
		}

		audio.drain(running);
		const int64_t loop_end = now_ns() + 20'000'000;
		while (running && audio.wants_more() && !g_stop && now_ns() < loop_end)
		{
			const s64 end = board->time() + TICKS_PER_MS;
			// the ring's entries due before the end of this millisecond
			uint32_t count = uint32_t(sh.read64(OFF_COUNT));
			if (count - rd > RING) rd = count - RING;       // overrun: the oldest are lost
			const int64_t t0 = now_ns();
			while (rd != count)
			{
				const uint64_t e = sh.read64(OFF_RING + (rd % RING) * 8);
				const uint32_t us = uint32_t(e);
				s64 tick = s64(us) * 16 + offset;
				if (!mapped || tick < board->time() - 50 * TICKS_PER_MS || tick > board->time() + 100 * TICKS_PER_MS)
				{
					// first entry, or the clocks have drifted apart: map this stamp LAT ahead
					offset = board->time() + LAT - s64(us) * 16;
					tick = board->time() + LAT;
					mapped = true;
				}
				else tick = std::max(tick, last_tick + s64(us - last_us) * 16);
				if (tick >= end) break;
				board->run_until(std::max(tick, board->time()));
				apply(e);
				last_tick = std::max(tick, board->time());
				last_us = us;
				rd++;
			}
			board->run_until(end);
			busy_ns += now_ns() - t0;

			rf5c400 &pc = board->pcm();
			pcm.clear();
			rs.run(pc.m_out, pc.m_out.size() / rf5c400::OUTPUTS, rf5c400::OUTPUTS, 0, 1, pcm);
			pc.discard();
			audio.put(pcm, false);
			publish();
			audio.drain(running);
		}
		if (!running) publish();
		if (verbose && now_ns() - rep_t >= 5'000'000'000)
		{
			const double span = double(now_ns() - rep_t);
			fprintf(stderr, "arcsnd hornet: %s, %u entries, busy %.0f%% (CPU %.0f%%), %u gaps (%.0f ms)\n",
			        running ? "running" : "idle", rep_entries, 100.0 * busy_ns / span,
			        100.0 * (cpu_ns() - rep_cpu) / span, audio.gaps, audio.gap_ns / 1e6);
			rep_t = now_ns(); rep_cpu = cpu_ns(); busy_ns = 0; rep_entries = 0; audio.gaps = 0; audio.gap_ns = 0;
		}
		if (!running || !audio.wants_more()) sleep_ns(1'000'000);
	}
	stop("the core changed");
	publish();
	unmap(p, SHM_SIZE);
}
