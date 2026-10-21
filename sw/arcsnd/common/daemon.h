// SPDX-License-Identifier: GPL-3.0-or-later
// What every board's session shares (from hng64snd's mister.cpp): time, /tmp/CORENAME, the
// uncached shared block, and /dev/MrAudio, the framework's ALSA path, paced by a model of its
// buffer.
#pragma once

#include <csignal>
#include <cstdint>
#include <string>
#include <vector>

namespace arcsnd {

extern volatile sig_atomic_t g_stop;

int64_t now_ns();
int64_t cpu_ns();
void sleep_ns(int64_t ns);

// Main_MiSTer's /tmp/CORENAME: the set's name, and when it was written, which it is at every
// core load (one set straight to another, or the same again, included)
struct core_name
{
	std::string name;
	int64_t written = -1;
};
core_name read_core_name();

// a block of DDR3, uncached. The FPGA writes whole 64-bit words; a 32-bit read of a word's two
// halves can straddle its update, so a word is read until two reads agree.
struct shared
{
	volatile uint32_t *w = nullptr;
	uint64_t read64(uint32_t off) const
	{
		for (;;)
		{
			const uint32_t lo = w[off / 4], hi = w[off / 4 + 1];
			if (w[off / 4] == lo && w[off / 4 + 1] == hi) return uint64_t(hi) << 32 | lo;
		}
	}
	void write32(uint32_t off, uint32_t v) { w[off / 4] = v; }
	const volatile uint8_t *bytes(uint32_t off) const { return reinterpret_cast<const volatile uint8_t *>(w) + off; }
};

// mem: /dev/mem; maps `size` bytes at physical `addr` (page aligned), nullptr on failure
void *map(int mem, uint32_t addr, uint32_t size);
void unmap(void *p, uint32_t size);
// 32-bit loads: the mapping is device memory, which takes no unaligned or wider access well
void copy_in(void *dst, const volatile uint8_t *src, size_t n);

constexpr int OUT_RATE = 48000;

// in_rate to 48 kHz, linear between neighbours; in: frames of `stride` s32, left at l, right at r
struct resampler
{
	double step = 44100.0 / OUT_RATE;
	double phase = 0.0;              // position of the next output, in input samples past `prev`
	int32_t prev_l = 0, prev_r = 0;
	void run(const std::vector<int32_t> &in, size_t frames, int stride, int l, int r, std::vector<int16_t> &out);
};

// /dev/MrAudio. sys/alsa.sv plays its buffer at 48 kHz, faster (at most 0.53%) only past 16 KB,
// 85 ms, and holds the last sample when it is empty. The device takes all it is given, so the
// buffer's level is modelled: frames written less those played since. The model plays 0.02%
// fast, so a slower FPGA clock leaves the real level above it, where alsa.sv's speed-up holds it.
struct audio_out
{
	static constexpr double LEAD_FRAMES = OUT_RATE * 0.080;
	static constexpr double PLAY_PER_NS = OUT_RATE * 1.0002 / 1e9;

	int fd = -1;
	double level = 0;                // frames, modelled
	int64_t level_t = 0;
	int16_t last_l = 0, last_r = 0;
	std::vector<int16_t> outq;       // written 5 ms at a time: a write a millisecond took CPU
	uint32_t gaps = 0;
	int64_t gap_ns = 0;

	void open_dev();
	void close_dev();
	// the level after what alsa.sv has played since; an empty buffer while `playing` is a gap
	void drain(bool playing);
	void put(const std::vector<int16_t> &pcm, bool now);
	// 5 ms down to 0 from the last sample, which alsa.sv would otherwise hold
	void fade();
	bool wants_more() const { return level + outq.size() / 2 < LEAD_FRAMES; }
};

}  // namespace arcsnd
