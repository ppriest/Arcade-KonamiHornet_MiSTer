// SPDX-License-Identifier: GPL-3.0-or-later
// The Hornet sound board against a MAME capture (scripts/mame_sndlog.py): the PPC's SNDRES and
// K056800 host writes are replayed at their times; every value the PPC read from the K056800 in
// MAME is checked against host_r at the same time, and the 68000's K056800 writes are compared in
// order. The RF5C400's left and right go to a 44.1 kHz wav.
//
//   hornet_bench <audiocpu.bin> <rfsnd.bin> <sndlog.txt> <out.wav> [-v]

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "board.h"

namespace {

std::vector<u8> load(const char *path)
{
	std::vector<u8> b;
	FILE *f = fopen(path, "rb");
	if (!f) { perror(path); exit(2); }
	fseek(f, 0, SEEK_END);
	b.resize(size_t(ftell(f)));
	fseek(f, 0, SEEK_SET);
	if (fread(b.data(), 1, b.size(), f) != b.size()) { perror(path); exit(2); }
	fclose(f);
	return b;
}

struct event
{
	s64 t;          // 16 MHz ticks
	char who;       // 'P' the PPC, 'S' the 68000
	char rw;
	u32 addr, data, mask;
};

// a PPC access's byte: the tap gives the 32-bit word's offset and the lane in the mask
bool lane(u32 mask, u32 data, int &k, u8 &v)
{
	for (k = 0; k < 4; k++)
	{
		const u32 m = 0xffu << (24 - 8 * k);
		if (mask == m) { v = u8(data >> (24 - 8 * k)); return true; }
	}
	return false;
}

void write_wav(const char *path, const std::vector<int16_t> &pcm, int rate)
{
	FILE *f = fopen(path, "wb");
	if (!f) { perror(path); return; }
	const u32 data = u32(pcm.size() * 2);
	auto w32 = [&](u32 v) { fwrite(&v, 4, 1, f); };
	auto w16 = [&](u16 v) { fwrite(&v, 2, 1, f); };
	fwrite("RIFF", 1, 4, f); w32(36 + data); fwrite("WAVEfmt ", 1, 8, f);
	w32(16); w16(1); w16(2); w32(u32(rate)); w32(u32(rate * 4)); w16(4); w16(16);
	fwrite("data", 1, 4, f); w32(data);
	fwrite(pcm.data(), 2, pcm.size(), f);
	fclose(f);
}

}

int main(int argc, char **argv)
{
	if (argc < 5)
	{
		fprintf(stderr, "usage: hornet_bench <audiocpu.bin> <rfsnd.bin> <sndlog.txt> <out.wav> [-v]\n");
		return 2;
	}
	const bool verbose = argc > 5 && !strcmp(argv[5], "-v");
	const std::vector<u8> prog = load(argv[1]), smp = load(argv[2]);

	std::vector<event> ev;
	{
		FILE *f = fopen(argv[3], "r");
		if (!f) { perror(argv[3]); return 2; }
		char who[8], rw[4];
		unsigned a, d, m;
		double us;
		char line[256];
		while (fgets(line, sizeof line, f))
		{
			if (sscanf(line, "%7s %3s %x %x %x %lf", who, rw, &a, &d, &m, &us) != 6) continue;
			if (strcmp(who, "PPC") && strcmp(who, "SND")) continue;
			ev.push_back({s64(us * 16.0 + 0.5), who[0] == 'P' ? 'P' : 'S', rw[0], a, d, m});
		}
		fclose(f);
	}

	hornet_board board(prog.data(), smp.data(), u32(smp.size()));
	std::vector<std::pair<s64, u32>> ours;          // the port's 68000 K056800 writes: (tick, addr << 8 | data)
	board.m_log = [&](s64 t, char rw, u32 a, u32 d) {
		if (rw == 'W' && a >= 0x300000 && a < 0x300020) ours.push_back({t, (a & 0x1f) << 8 | (d & 0xff)});
	};

	std::vector<int16_t> wav;
	auto drain = [&] {
		rf5c400 &p = board.pcm();
		for (size_t i = 0; i + 3 < p.m_out.size(); i += rf5c400::OUTPUTS)
			for (int c = 0; c < 2; c++)
				wav.push_back(int16_t(std::max(-32768, std::min(32767, p.m_out[i + c]))));
		p.discard();
	};

	int reads = 0, read_bad = 0, read_early = 0, shown = 0;
	constexpr s64 QUANTUM = 16'000'000 / 6000;
	std::vector<std::pair<s64, u32>> mame;          // MAME's 68000 K056800 writes
	for (const event &e : ev)
	{
		if (e.who == 'S')
		{
			if (e.rw == 'W' && e.addr >= 0x300000 && e.addr < 0x300020)
				mame.push_back({e.t, (e.addr & 0x1f) << 8 | (e.data & 0xff)});
			continue;
		}
		// a read sees the 68000 as it was up to a MAME quantum (hornet.cpp: 1/6000 s) earlier: the
		// PPC runs first in each slice and the 68000 catches up after it
		int k;
		u8 v;
		const bool lane_ok = lane(e.mask, e.data, k, v);
		board.run_until(e.t);
		// whether the reply register held MAME's value at some time in the quantum before the read:
		// MAME's PPC sees the 68000 as it stood anywhere from a slice's start (the 68000 runs after
		// the PPC) to now (a write to the K056800 synchronises them)
		bool early_ok = false;
		if (lane_ok && e.rw == 'R')
		{
			const u32 reg = ((e.addr & 0xffff) + u32(k)) & 7;
			u8 v0;
			lane(e.mask, e.data, k, v0);
			for (size_t i = ours.size(); i-- > 0;)
			{
				if ((ours[i].second >> 9) != reg) continue;
				if (u8(ours[i].second) == v0) { early_ok = true; break; }
				if (ours[i].first <= e.t - QUANTUM) break;
			}
		}
		drain();
		if (!lane_ok) continue;
		const u32 byte = (e.addr & 0xffff) + u32(k);
		if (e.addr >= 0x7d010000 && e.addr < 0x7d010010)
		{
			if (byte == 4 && e.rw == 'W') board.sndres_w(v & 0x80);
		}
		else if (e.addr >= 0x7d030000 && e.addr < 0x7d030010)
		{
			if (e.rw == 'W') board.host_w(int(byte & 7), v);
			else
			{
				reads++;
				const u8 got = board.host_r(int(byte & 7));
				if (got != v && early_ok) read_early++;
				else if (got != v)
				{
					read_bad++;
					if (shown++ < 12)
						printf("PPC read of K056800 %u at %.3f ms: MAME %02X, port %02X\n", byte & 7, e.t / 16000.0, v, got);
				}
			}
		}
	}
	board.run_until(board.time() + 16000);
	drain();

	// the 68000's replies, in order, and how far apart in time
	size_t n = std::min(ours.size(), mame.size()), same = 0;
	s64 worst = 0;
	for (size_t i = 0; i < n; i++)
	{
		if (ours[i].second == mame[i].second)
		{
			same++;
			worst = std::max(worst, std::llabs(ours[i].first - mame[i].first));
		}
		else if (verbose && same == i)
			printf("68000 K056800 write %zu: MAME %04X at %.3f ms, port %04X at %.3f ms\n", i, mame[i].second,
			       mame[i].first / 16000.0, ours[i].second, ours[i].first / 16000.0);
	}
	size_t prefix = 0;
	while (prefix < n && ours[prefix].second == mame[prefix].second) prefix++;
	if (verbose && prefix < n)
		for (size_t i = prefix >= 4 ? prefix - 4 : 0; i < std::min(n, prefix + 6); i++)
			printf("  %zu  MAME %04X at %.3f ms   port %04X at %.3f ms\n", i, mame[i].second, mame[i].first / 16000.0,
			       ours[i].second, ours[i].first / 16000.0);
	printf("PPC reads of the K056800: %d; %d as the port had them within %d us before (MAME's quantum), %d differ\n",
	       reads, read_early, int(QUANTUM / 16), read_bad);
	printf("68000 K056800 writes: MAME %zu, port %zu; the first %zu identical (furthest apart %.1f us)\n",
	       mame.size(), ours.size(), prefix, worst / 16.0);
	printf("68000 cycles %lld over %.3f s\n", (long long)board.m_cycles_run, board.time() / 16e6);
	write_wav(argv[4], wav, hornet_board::SAMPLE_RATE);
	printf("-> %s, %zu frames\n", argv[4], wav.size() / 2);
	return read_bad == 0 && prefix == n ? 0 : 1;
}
