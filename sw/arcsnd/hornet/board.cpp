// license:BSD-3-Clause
// copyright-holders:Ville Linde
// The Hornet sound board (board.h, PROVENANCE.md).

#include <algorithm>
#include <cstring>
#include "board.h"

extern "C" {
#include "musashi/m68k.h"
}

namespace {

hornet_board *g_board = nullptr;            // Musashi has one CPU, in globals

constexpr s64 UPDATE_TICKS = hornet_board::CPU_HZ / 50;    // MAME's STREAMS_UPDATE_FREQUENCY

}

extern "C" {
unsigned int m68k_read_memory_8(unsigned int a) { return g_board->read8(a & 0xffffff); }
unsigned int m68k_read_memory_16(unsigned int a) { return g_board->read16(a & 0xffffff); }
unsigned int m68k_read_memory_32(unsigned int a)
{
	return g_board->read16(a & 0xffffff) << 16 | g_board->read16((a + 2) & 0xffffff);
}
void m68k_write_memory_8(unsigned int a, unsigned int d) { g_board->write8(a & 0xffffff, d & 0xff); }
void m68k_write_memory_16(unsigned int a, unsigned int d) { g_board->write16(a & 0xffffff, d & 0xffff); }
void m68k_write_memory_32(unsigned int a, unsigned int d)
{
	g_board->write16(a & 0xffffff, d >> 16);
	g_board->write16((a + 2) & 0xffffff, d & 0xffff);
}
unsigned int m68k_read_disassembler_16(unsigned int a) { return g_board->read16(a & 0xffffff); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return m68k_read_memory_32(a); }
}

hornet_board::hornet_board(const u8 *prog, const u8 *samples, u32 samples_bytes)
	: m_prog(new u8[0x80000]), m_ram(new u8[0x10000]), m_pcm(samples, samples_bytes, PCM_CLOCK)
{
	for (u32 i = 0; i < 0x80000; i += 2)
	{
		m_prog[i] = prog[i + 1];
		m_prog[i + 1] = prog[i];
	}
	memset(m_ram.get(), 0, 0x10000);
	g_board = this;
	m68k_init();
	m68k_set_cpu_type(M68K_CPU_TYPE_68000);
	restart_timer(0);
	m68k_pulse_reset();
	m_next_update = UPDATE_TICKS;
}

hornet_board::~hornet_board()
{
	if (g_board == this) g_board = nullptr;
}

// the periodic interrupt (16.9344 MHz / 384 / 128) restarts with the CPU: MAME's set_periodic_int
// timer is adjusted in the device's reset, which releasing its reset line runs
void hornet_board::restart_timer(s64 t)
{
	m_timer_base = t;
	m_timer_n = 1;
	m_next_timer = t + tick_of(128);
}

s64 hornet_board::now() const
{
	return m_in_cpu ? m_slice_start + m68k_cycles_run() : m_time;
}

void hornet_board::update_irq()
{
	m68k_set_irq(m_irq2 ? 2 : m_irq1 ? 1 : 0);
}

void hornet_board::stream_to(s64 t)
{
	m_pcm.update_to(sample_at(t));
}

// sysreg_w, register 4: SNDRES 0 asserts the 68000's reset line, 1 clears it; a change of SNDRES
// clears IRQ1. MAME's machine reset leaves the line clear, so the 68000 runs from power-on.
void hornet_board::sndres_w(bool run)
{
	if (run && !m_running)
	{
		m68k_pulse_reset();
		restart_timer(now());
	}
	m_running = run;
	if (run != m_sndres)
	{
		m_irq1 = false;
		update_irq();
	}
	m_sndres = run;
}

// k056800_device::host_w / host_r
void hornet_board::host_w(int reg, u8 data)
{
	switch (reg & 7)
	{
		case 0: case 1: case 2: case 3:
			m_host_to_snd[reg & 3] = data;
			break;
		case 7:     // sound interrupt
			if (m_int_enabled)
			{
				m_int_pending = true;
				m_irq2 = true;
				update_irq();
			}
			break;
		default:    // 4-6: volume and mute, not emulated
			break;
	}
}

u8 hornet_board::host_r(int reg)
{
	switch (reg & 7)
	{
		case 0: case 1: return m_snd_to_host[reg & 1];
		default: return 0;
	}
}

void hornet_board::run_until(s64 t)
{
	while (m_time < t)
	{
		const s64 next = std::min({t, m_next_timer, m_next_update});
		if (m_running && m_time < next)
		{
			m_slice_start = m_time;
			m_in_cpu = true;
			const int used = m68k_execute(int(next - m_time));
			m_in_cpu = false;
			m_time += used;
			m_cycles_run += used;
		}
		else
			m_time = next;
		while (m_time >= m_next_timer)
		{
			// sound_irq, 16.9344 MHz / 384 / 128: every 128th PCM sample
			if (m_timer_enabled)
			{
				m_irq1 = true;
				update_irq();
			}
			m_next_timer = m_timer_base + tick_of(128 * ++m_timer_n);
		}
		while (m_time >= m_next_update)
		{
			stream_to(m_next_update);
			m_next_update += UPDATE_TICKS;
		}
	}
}

// ---------------------------------------------------------------------- the 68000's memory map

u32 hornet_board::read16(u32 a)
{
	if (a < 0x080000) return u32(m_prog[a] << 8 | m_prog[a + 1]);
	if (a >= 0x100000 && a < 0x110000) return u32(m_ram[a - 0x100000] << 8 | m_ram[a - 0x100000 + 1]);
	if (a >= 0x200000 && a < 0x201000)
	{
		const offs_t o = (a & 0xfff) >> 1;
		if (o == 0x09) stream_to(now());        // the position read updates the stream (MAME)
		return m_pcm.read(o);
	}
	if (a >= 0x300000 && a < 0x300020)
	{
		// k056800_device::sound_r on the low byte (umask16 0x00ff)
		const int r = (a >> 1) & 7;
		const u8 d = r < 4 ? m_host_to_snd[r] : 0;
		if (m_log) m_log(now(), 'R', a, d);
		return d;
	}
	return 0;
}

u32 hornet_board::read8(u32 a)
{
	const u32 w = read16(a & ~1u);
	return (a & 1) ? (w & 0xff) : (w >> 8);
}

void hornet_board::write16(u32 a, u32 d)
{
	if (a >= 0x100000 && a < 0x110000)
	{
		m_ram[a - 0x100000] = u8(d >> 8);
		m_ram[a - 0x100000 + 1] = u8(d);
		return;
	}
	if (a >= 0x200000 && a < 0x201000)
	{
		m_pcm.write((a & 0xfff) >> 1, u16(d));
		return;
	}
	if (a >= 0x300000 && a < 0x300020)
	{
		// k056800_device::sound_w on the low byte
		const int r = (a >> 1) & 7;
		const u8 v = u8(d);
		if (m_log) m_log(now(), 'W', a, v);
		switch (r)
		{
			case 0: case 1:
				m_snd_to_host[r] = v;
				break;
			case 4:     // sound CPU interrupt control
				m_int_enabled = (v & 1) != 0;
				if (m_int_enabled)
				{
					if (m_int_pending) m_irq2 = true;
				}
				else
				{
					m_int_pending = false;
					m_irq2 = false;
				}
				update_irq();
				break;
			default:
				break;
		}
		return;
	}
	if (a >= 0x500000 && a < 0x500002)      // soundtimer_en_w
	{
		if (m_log) m_log(now(), 'W', a, d);
		m_timer_enabled = !(d & 1);
		return;
	}
	if (a >= 0x600000 && a < 0x600002)      // soundtimer_ack_w
	{
		m_irq1 = false;
		update_irq();
		return;
	}
}

void hornet_board::write8(u32 a, u32 d)
{
	// a byte on a 16-bit bus: in the word's high half at an even address, the low half at odd
	if (a >= 0x100000 && a < 0x110000) { m_ram[a - 0x100000] = u8(d); return; }
	if (a >= 0x300000 && a < 0x300020)
	{
		if (a & 1) write16(a & ~1u, d);         // the K056800 is on the low byte only
		return;
	}
	write16(a & ~1u, (a & 1) ? d : d << 8);
}
