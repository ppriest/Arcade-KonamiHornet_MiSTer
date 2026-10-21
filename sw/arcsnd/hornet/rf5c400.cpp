// license:BSD-3-Clause
// copyright-holders:Ville Linde
/*
    Ricoh RF5C400 emulator

    Written by Ville Linde
    Improvements by the hoot development team

    From MAME src/devices/sound/rf5c400.cpp (PROVENANCE.md). The stream's add_int(..., 32768) is
    kept as the integer it adds; the external memory write (register 0x14) goes nowhere, the
    samples being ROM on Hornet.
*/

#include <algorithm>
#include <cmath>
#include "rf5c400.h"

namespace {

int volume_table[256];
double pan_table[256];

void init_static_tables()
{
	std::fill(std::begin(pan_table), std::end(pan_table), 0.0);

	// init volume/pan tables
	double max = 255.0;
	for (int i = 0; i < 256; i++) {
		volume_table[i] = uint16_t(max);
		max /= pow(10.0, double((4.5 / (256.0 / 16.0)) / 20));
	}
	for (int i = 0; i < 0x48; i++) {
		pan_table[i] = sqrt(double(0x47 - i)) / sqrt(double(0x47));
	}
}

/* PCM type */
enum
{
	TYPE_MASK       = 0x00C0,
	TYPE_16         = 0x0000,
	TYPE_8LOW       = 0x0040,
	TYPE_8HIGH      = 0x0080
};

/* envelope phase */
enum
{
	PHASE_NONE      = 0,
	PHASE_ATTACK,
	PHASE_DECAY,
	PHASE_RELEASE
};

} // anonymous namespace

void rf5c400::envelope_tables::init(u32 clock)
{
	/* envelope parameter (experimental) */
	static constexpr double ENV_AR_SPEED    = 0.1;
	static constexpr int    ENV_MIN_AR      = 0x02;
	static constexpr int    ENV_MAX_AR      = 0x80;
	static constexpr double ENV_DR_SPEED    = 2.0;
	static constexpr int    ENV_MIN_DR      = 0x20;
	static constexpr int    ENV_MAX_DR      = 0x73;
	static constexpr double ENV_RR_SPEED    = 0.7;
	static constexpr int    ENV_MIN_RR      = 0x20;
	static constexpr int    ENV_MAX_RR      = 0x54;

	double r;

	// attack
	r = 1.0 / (ENV_AR_SPEED * (clock / 384));
	for (int i = 0; i < ENV_MIN_AR; i++)
		m_ar[i] = 1.0;
	for (int i = ENV_MIN_AR; i < ENV_MAX_AR; i++)
		m_ar[i] = r * (ENV_MAX_AR - i) / (ENV_MAX_AR - ENV_MIN_AR);
	for (int i = ENV_MAX_AR; i < 0x9f; i++)
		m_ar[i] = 0.0;

	// decay
	r = -5.0 / (ENV_DR_SPEED * (clock / 384));
	for (int i = 0; i < ENV_MIN_DR; i++)
		m_dr[i] = r;
	for (int i = ENV_MIN_DR; i < ENV_MAX_DR; i++)
		m_dr[i] = r * (ENV_MAX_DR - i) / (ENV_MAX_DR - ENV_MIN_DR);
	for (int i = ENV_MAX_DR; i < 0x9f; i++)
		m_dr[i] = 0.0;

	// release
	r = -5.0 / (ENV_RR_SPEED * (clock / 384));
	for (int i = 0; i < ENV_MIN_RR; i++)
		m_rr[i] = r;
	for (int i = ENV_MIN_RR; i < ENV_MAX_RR; i++)
		m_rr[i] = r * (ENV_MAX_RR - i) / (ENV_MAX_RR - ENV_MIN_RR);
	for (int i = ENV_MAX_RR; i < 0x9f; i++)
		m_rr[i] = 0.0;
}

rf5c400::rf5c400(const u8 *rom, u32 rom_bytes, u32 clock) : m_rom(rom), m_mask(rom_bytes - 1)
{
	init_static_tables();
	m_env.init(clock);
}

void rf5c400::update_to(s64 n)
{
	if (n > m_done)
	{
		render(int(n - m_done));
		m_done = n;
	}
}

// sound_stream_update for n samples, appended to m_out
void rf5c400::render(int n)
{
	const size_t base = m_out.size();
	m_out.resize(base + size_t(n) * OUTPUTS, 0);
	s32 *out = m_out.data() + base;

	int i, ch;
	uint64_t start, end, loop;
	uint64_t pos;
	uint8_t vol, lvol, rvol, effect_lvol, effect_rvol, type;
	uint8_t env_phase;
	double env_level, env_step, env_rstep;

	for (ch=0; ch < 32; ch++)
	{
		channel *channel = &m_channels[ch];

		start = ((uint32_t)(channel->startH & 0xFF00) << 8) | channel->startL;
		end = ((uint32_t)(channel->endHloopH & 0xFF) << 16) | channel->endL;
		loop = ((uint32_t)(channel->endHloopH & 0xFF00) << 8) | channel->loopL;
		pos = channel->pos;
		vol = channel->volume & 0xFF;
		lvol = channel->pan & 0xFF;
		rvol = channel->pan >> 8;
		effect_lvol = channel->effect & 0xFF;
		effect_rvol = channel->effect >> 8;
		type = (channel->volume >> 8) & TYPE_MASK;

		env_phase = channel->env_phase;
		env_level = channel->env_level;
		env_step = channel->env_step;
		env_rstep = env_step * channel->env_scale;

		if (start == end)
		{
			// This occurs in pop'n music when trying to play a non-existent sample on the sound test menu
			continue;
		}

		for (i=0; i < n; i++)
		{
			int16_t tmp;
			int32_t sample;

			if (env_phase == PHASE_NONE) break;

			tmp = read_word((pos>>16)<<1);
			switch ( type )
			{
				case TYPE_16:
					sample = tmp;
					break;
				case TYPE_8LOW:
					sample = (int16_t)(tmp << 8);
					break;
				case TYPE_8HIGH:
					sample = (int16_t)(tmp & 0xFF00);
					break;
				default:
					sample = 0;
					break;
			}

			if ( sample & 0x8000 )
			{
				sample ^= 0x7FFF;
			}

			env_level += env_rstep;
			switch (env_phase)
			{
			case PHASE_ATTACK:
				if (env_level >= 1.0)
				{
					env_phase = PHASE_DECAY;
					env_level = 1.0;
					if ((channel->decay & 0x0080) || (channel->decay == 0x100))
					{
						env_step = 0.0;
					}
					else
					{
						env_step = m_env.dr(*channel);
					}
					env_rstep = env_step * channel->env_scale;
				}
				break;
			case PHASE_DECAY:
				if (env_level <= 0.0)
				{
					env_phase = PHASE_NONE;
					env_level = 0.0;
					env_step = 0.0;
					env_rstep = 0.0;
				}
				break;
			case PHASE_RELEASE:
				if (env_level <= 0.0)
				{
					env_phase = PHASE_NONE;
					env_level = 0.0;
					env_step = 0.0;
					env_rstep = 0.0;
				}
				break;
			}

			sample *= volume_table[vol];
			sample = (sample >> 9) * env_level;
			out[i * OUTPUTS + 0] += s32(sample * pan_table[lvol]);
			out[i * OUTPUTS + 1] += s32(sample * pan_table[rvol]);
			out[i * OUTPUTS + 2] += s32(sample * pan_table[effect_lvol]);
			out[i * OUTPUTS + 3] += s32(sample * pan_table[effect_rvol]);

			pos += channel->step;
			if ((pos>>16) > end)
			{
				pos -= loop<<16;
				pos &= 0xFFFFFF0000ULL;

				if (pos < (start<<16))
				{
					// This case only shows up in Firebeat games from what I could tell.
					// The loop value will be higher than the actual buffer size.
					// This is used when DMAs will be overwriting the current buffer.
					// It expects the buffer to be looped without any additional commands.
					pos = start<<16;
				}
			}

		}
		channel->pos = pos;

		channel->env_phase = env_phase;
		channel->env_level = env_level;
		channel->env_step = env_step;
	}
}

/*****************************************************************************/

u16 rf5c400::read(offs_t offset)
{
	if (offset < 0x400)
	{
		switch(offset)
		{
			case 0x00:
			{
				return m_status;
			}

			case 0x04:      // unknown read
			{
				return 0;
			}

			case 0x09:      // position read?
			{
				// The caller has run the stream to now (MAME's m_stream->update()).
				channel* channel = &m_channels[m_req_channel];
				if (channel->env_phase == PHASE_NONE)
				{
					return 0;
				}
				auto start = ((uint32_t)(channel->startH & 0xFF00) << 8) | channel->startL;
				auto ch_offset = (channel->pos >> 16) - start;
				return ch_offset >> 6;
			}

			case 0x13:      // memory read
			{
				return read_word(m_ext_mem_address<<1);
			}

			default:
			{
				return 0;
			}
		}
	}
	else
	{
		int reg = (offset & 0x1f);

		switch (reg)
		{
		case 0x0F:      // unknown read
			return 0;

		default:
			return 0;
		}
	}
}

void rf5c400::write(offs_t offset, u16 data)
{
	if (offset < 0x400)
	{
		switch(offset)
		{
			case 0x00:
			{
				m_status = data;
				break;
			}

			case 0x01:      // channel control
			{
				int ch = data & 0x1f;
				switch ( data & 0x60 )
				{
					case 0x60:
						m_channels[ch].pos =
							((uint32_t)(m_channels[ch].startH & 0xFF00) << 8) | m_channels[ch].startL;
						m_channels[ch].pos <<= 16;

						m_channels[ch].env_phase = PHASE_ATTACK;
						m_channels[ch].env_level = 0.0;
						m_channels[ch].env_step  = m_env.ar(m_channels[ch]);
						break;
					case 0x40:
						if (m_channels[ch].env_phase != PHASE_NONE)
						{
							m_channels[ch].env_phase = PHASE_RELEASE;
							if (m_channels[ch].release & 0x0080)
							{
								m_channels[ch].env_step = 0.0;
							}
							else
							{
								m_channels[ch].env_step = m_env.rr(m_channels[ch]);
							}
						}
						break;
					default:
						m_channels[ch].env_phase = PHASE_NONE;
						m_channels[ch].env_level = 0.0;
						m_channels[ch].env_step  = 0.0;
						break;
				}
				break;
			}

			case 0x08:
			{
				m_req_channel = data & 0x1f;
				break;
			}

			case 0x09:      // relative to env attack (0x0c00/ 0x1c00/ 0x1e00)

			case 0x11:      // memory r/w address, bits 15 - 0
			{
				m_ext_mem_address &= ~0xffff;
				m_ext_mem_address |= data;
				break;
			}
			case 0x12:      // memory r/w address, bits 23 - 16
			{
				m_ext_mem_address &= 0xffff;
				m_ext_mem_address |= (uint32_t)(data) << 16;
				break;
			}
			case 0x13:      // memory write data
			{
				m_ext_mem_data = data;
				break;
			}

			case 0x14:      // memory write: the samples are ROM here
				break;

			default:
				break;
		}
	}
	else
	{
		// channel registers
		int ch = (offset >> 5) & 0x1f;
		int reg = (offset & 0x1f);

		channel *channel = &m_channels[ch];

		switch (reg)
		{
			case 0x00:      // sample start address, bits 23 - 16
				channel->startH = data;
				break;
			case 0x01:      // sample start address, bits 15 - 0
				channel->startL = data;
				break;
			case 0x02:      // sample playing frequency
				channel->step = ((data & 0x1fff) << (data >> 13)) * 4;
				channel->freq = data;
				break;
			case 0x03:      // sample end address, bits 15 - 0
				channel->endL = data;
				break;
			case 0x04:      // sample end address, bits 23 - 16 , sample loop 23 - 16
				channel->endHloopH = data;
				break;
			case 0x05:      // sample loop offset, bits 15 - 0
				channel->loopL = data;
				break;
			case 0x06:      // channel volume
				channel->pan = data;
				break;
			case 0x07:      // effect depth
				channel->effect = data;
				break;
			case 0x08:      // volume, flag
				channel->volume = data;
				break;
			case 0x09:      // env attack
				channel->attack = data;
				break;
			case 0x0C:      // env decay
				channel->decay = data;
				break;
			case 0x0E:      // env release
				channel->release = data;
				break;
			case 0x10:      // resonance, cutoff freq.
				channel->cutoff = data;
				break;
			default:        // 0x0A, 0x0B, 0x0D, 0x0F: unknown, ignored by MAME
				break;
		}
	}
}
