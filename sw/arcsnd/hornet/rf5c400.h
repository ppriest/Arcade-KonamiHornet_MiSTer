// license:BSD-3-Clause
// copyright-holders:Ville Linde
// Ricoh RF5C400, from MAME src/devices/sound/rf5c400.h (PROVENANCE.md): the device, stream and
// ROM interfaces replaced by a sample ROM pointer and an output buffer the board drains.
#pragma once

#include <vector>
#include "mame_shim.h"

class rf5c400
{
public:
	// rom: the sample region, little-endian 16-bit words; rom_bytes a power of two (reads wrap)
	rf5c400(const u8 *rom, u32 rom_bytes, u32 clock);

	u16 read(offs_t offset);
	void write(offs_t offset, u16 data);

	// runs the stream to output sample n (exclusive): MAME's stream update
	void update_to(s64 n);
	s64 samples_done() const { return m_done; }

	// MAME's four outputs (left, right, effect left, effect right) as its integer sums, a frame of
	// OUTPUTS per sample, appended as the stream runs; the board takes and discards them
	static constexpr int OUTPUTS = 4;
	std::vector<s32> m_out;
	void discard() { m_out.clear(); }

private:
	struct channel
	{
		u16 startH = 0, startL = 0, freq = 0, endL = 0, endHloopH = 0, loopL = 0, pan = 0, effect = 0, volume = 0;
		u16 attack = 0, decay = 0, release = 0, cutoff = 0;
		u64 pos = 0, step = 0;
		u16 keyon = 0;
		u8 env_phase = 0;
		double env_level = 0.0, env_step = 0.0, env_scale = 1.0;
	};

	struct envelope_tables
	{
		void init(u32 clock);
		double ar(const channel &c) const { return m_ar[decode80(c.attack >> 8)]; }
		double dr(const channel &c) const { return m_dr[decode80(c.decay >> 8)]; }
		double rr(const channel &c) const { return m_rr[decode80(c.release >> 8)]; }
		static constexpr u8 decode80(u8 v) { return (v & 0x80) ? ((v & 0x7f) + 0x1f) : v; }
		double m_ar[0x9f] = {}, m_dr[0x9f] = {}, m_rr[0x9f] = {};
	};

	u16 read_word(u32 byteaddr) const
	{
		const u32 a = byteaddr & m_mask;
		return u16(m_rom[a] | m_rom[a + 1] << 8);
	}
	void render(int n);

	const u8 *m_rom;
	u32 m_mask;
	envelope_tables m_env;
	channel m_channels[32];
	u16 m_status = 0;
	u32 m_ext_mem_address = 0;
	u16 m_ext_mem_data = 0;
	u16 m_req_channel = 0;
	s64 m_done = 0;
};
