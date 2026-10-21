// license:BSD-3-Clause
// copyright-holders:Ville Linde
// The Hornet sound board: the 68000 (Musashi) at 16 MHz, 64 KB of RAM, the K056800's sound side,
// the 344.5 Hz timer interrupt and the RF5C400. From MAME src/mame/konami/hornet.cpp
// (sound_memmap, sysreg_w's SNDRES, sound_irq, soundtimer_*) and src/devices/sound/k056800.cpp
// (PROVENANCE.md), with the run loop MAME's scheduler gave it. Time is ticks of the 68000's
// 16 MHz clock.
#pragma once

#include <functional>
#include <memory>
#include "mame_shim.h"
#include "rf5c400.h"

class hornet_board
{
public:
	static constexpr u32 CPU_HZ = 16'000'000;
	static constexpr u32 PCM_CLOCK = 16'934'400;
	static constexpr int SAMPLE_RATE = PCM_CLOCK / 384;         // 44100

	// prog: the 68000's 512 KB as stored in the set (bytes swapped in each word, MAME's
	// ROM_LOAD16_WORD_SWAP); samples: the RF5C400's region (little-endian words), its size a
	// power of two
	hornet_board(const u8 *prog, const u8 *samples, u32 samples_bytes);
	~hornet_board();

	// the PPC's side, at the board's current time
	void sndres_w(bool run);                // system register 1 bit 7: 0 holds the 68000 in reset
	void host_w(int reg, u8 data);          // K056800 host registers 0-7 (0x7D030000 + reg)
	u8 host_r(int reg);

	// runs the 68000, the timer and the PCM stream to tick t
	void run_until(s64 t);
	s64 time() const { return m_time; }

	rf5c400 &pcm() { return m_pcm; }
	// the sample index of tick t, and the tick of sample n
	static s64 sample_at(s64 t) { return t * 441 / 160000; }
	static s64 tick_of(s64 n) { return (n * 160000 + 440) / 441; }

	// the 68000's K056800 and timer accesses, for the bench: (tick, 'R'/'W', address, data)
	std::function<void(s64, char, u32, u32)> m_log;
	s64 m_cycles_run = 0;

	// Musashi's memory callbacks land here
	u32 read8(u32 a);
	u32 read16(u32 a);
	void write8(u32 a, u32 d);
	void write16(u32 a, u32 d);

private:
	s64 now() const;
	void update_irq();
	void restart_timer(s64 t);
	void stream_to(s64 t);

	std::unique_ptr<u8[]> m_prog;           // in the 68000's byte order
	std::unique_ptr<u8[]> m_ram;
	rf5c400 m_pcm;

	// K056800
	u8 m_host_to_snd[4] = {}, m_snd_to_host[2] = {};
	bool m_int_pending = false, m_int_enabled = false;

	bool m_sndres = false;                  // the last SNDRES written (MAME's m_sndres)
	bool m_running = true;                  // the 68000's reset line clear: from power-on, until SNDRES is written 0
	bool m_timer_enabled = false;           // soundtimer_en_w
	bool m_irq1 = false, m_irq2 = false;

	s64 m_time = 0;
	s64 m_slice_end = 0;                    // the 68000's slice runs to here
	s64 m_next_timer = 0;                   // the 344.5 Hz interrupt's next tick
	s64 m_timer_base = 0, m_timer_n = 0;    // its period starts at the 68000's reset (MAME's interface_post_reset)
	s64 m_next_update = 0;                  // MAME's 50 Hz stream update's next tick
	s64 m_slice_start = 0;
	bool m_in_cpu = false;
};
