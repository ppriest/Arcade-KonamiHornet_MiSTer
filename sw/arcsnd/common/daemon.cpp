// SPDX-License-Identifier: GPL-3.0-or-later
// daemon.h's pieces, from hng64snd's mister.cpp.

#include "daemon.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace arcsnd {

volatile sig_atomic_t g_stop = 0;

int64_t now_ns()
{
	timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return int64_t(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

int64_t cpu_ns()
{
	timespec ts;
	clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
	return int64_t(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

void sleep_ns(int64_t ns)
{
	timespec ts{time_t(ns / 1'000'000'000), long(ns % 1'000'000'000)};
	nanosleep(&ts, nullptr);
}

core_name read_core_name()
{
	core_name c;
	struct stat st;
	if (stat("/tmp/CORENAME", &st) != 0) return c;
	c.written = int64_t(st.st_mtim.tv_sec) * 1'000'000'000 + st.st_mtim.tv_nsec;
	char name[64] = {};
	FILE *f = fopen("/tmp/CORENAME", "r");
	if (!f) return c;
	const size_t n = fread(name, 1, sizeof name - 1, f);
	fclose(f);
	name[n] = 0;
	name[strcspn(name, "\r\n")] = 0;
	c.name = name;
	return c;
}

void *map(int mem, uint32_t addr, uint32_t size)
{
	void *p = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, mem, addr);
	return p == MAP_FAILED ? nullptr : p;
}

void unmap(void *p, uint32_t size)
{
	if (p) munmap(p, size);
}

void copy_in(void *dst, const volatile uint8_t *src, size_t n)
{
	auto *d = static_cast<uint32_t *>(dst);
	auto *s = reinterpret_cast<const volatile uint32_t *>(src);
	for (size_t i = 0; i < n / 4; i++) d[i] = s[i];
}

void resampler::run(const std::vector<int32_t> &in, size_t frames, int stride, int li, int ri, std::vector<int16_t> &out)
{
	for (size_t i = 0; i < frames; i++)
	{
		const int32_t l = in[i * stride + li];
		const int32_t r = in[i * stride + ri];
		while (phase < 1.0)
		{
			const double a = prev_l + (l - prev_l) * phase;
			const double b = prev_r + (r - prev_r) * phase;
			out.push_back(int16_t(std::max(-32768.0, std::min(32767.0, a))));
			out.push_back(int16_t(std::max(-32768.0, std::min(32767.0, b))));
			phase += step;
		}
		phase -= 1.0;
		prev_l = l;
		prev_r = r;
	}
}

void audio_out::open_dev()
{
	if (fd >= 0) return;
	fd = open("/dev/MrAudio", O_WRONLY | O_NONBLOCK);
	if (fd < 0) perror("/dev/MrAudio");
	level_t = now_ns();
}

void audio_out::close_dev()
{
	if (fd >= 0) close(fd);
	fd = -1;
}

void audio_out::drain(bool playing)
{
	const int64_t t = now_ns();
	const double played = (t - level_t) * PLAY_PER_NS;
	if (playing && played > level)
	{
		if (level > 0) gaps++;
		gap_ns += int64_t((played - level) / PLAY_PER_NS);
	}
	level = std::max(0.0, level - played);
	level_t = t;
}

void audio_out::put(const std::vector<int16_t> &pcm, bool now)
{
	if (pcm.empty()) return;
	outq.insert(outq.end(), pcm.begin(), pcm.end());
	last_l = pcm[pcm.size() - 2];
	last_r = pcm[pcm.size() - 1];
	if (!now && outq.size() < 2 * 240) return;
	const ssize_t n = fd < 0 ? 0 : write(fd, outq.data(), outq.size() * sizeof(int16_t));
	if (n < 0) perror("MrAudio");
	else level += double(n / 4);
	outq.clear();
}

void audio_out::fade()
{
	std::vector<int16_t> f;
	for (int i = 1; i <= 240; i++)
	{
		f.push_back(int16_t(last_l * (240 - i) / 240));
		f.push_back(int16_t(last_r * (240 - i) / 240));
	}
	put(f, true);
}

}  // namespace arcsnd
