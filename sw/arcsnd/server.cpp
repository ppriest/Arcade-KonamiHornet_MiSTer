// SPDX-License-Identifier: GPL-3.0-or-later
// arcsnd: arcade sound boards on the MiSTer's ARM, for cores that leave their sound board to the
// HPS (PROVENANCE.md). One copy runs, in the background, from the Scripts menu or at boot
// (arcsnd.sh); it watches /tmp/CORENAME and runs the session of the board the loaded set has,
// each against its core's shared block in DDR3, until the core changes:
//
//   hornet  Konami Hornet (Gradius IV): hornet/session.cpp, rtl/mister/hornet_sndbridge.sv
//   hng64   SNK Hyper NeoGeo 64: hng64/session.cpp, HyperNG64's rtl/hng64_sndbridge.sv
//
//   arcsnd [-v]    -v: a line every 5 s on stderr

#include <fcntl.h>
#include <sched.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

#include "daemon.h"

bool hornet_claims(const char *name);
void hornet_run(int mem, bool verbose);
bool hng64_claims(const char *name);
void hng64_run(int mem, bool verbose);

namespace {
void on_signal(int) { arcsnd::g_stop = 1; }
}

int main(int argc, char **argv)
{
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	const bool verbose = argc > 1 && !strcmp(argv[1], "-v");

	const int mem = open("/dev/mem", O_RDWR | O_SYNC);
	if (mem < 0) { perror("/dev/mem"); return 1; }

	// one copy: two writing /dev/MrAudio interleave
	const int lock = open("/tmp/arcsnd.lock", O_RDWR | O_CREAT, 0644);
	if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0)
	{
		fprintf(stderr, "arcsnd: another copy is running\n");
		return 1;
	}

	// ahead of the daemons, not of the system: a real-time priority, once the process fell behind,
	// starved Main_MiSTer and sshd (HyperNG64, LESSONS_LEARNED). Core 0: Main_MiSTer's main thread
	// is pinned to core 1 and takes most of it.
	if (setpriority(PRIO_PROCESS, 0, -10) != 0) perror("setpriority");
	cpu_set_t cpus;
	CPU_ZERO(&cpus);
	CPU_SET(0, &cpus);
	if (sched_setaffinity(0, sizeof cpus, &cpus) != 0) perror("sched_setaffinity");

	while (!arcsnd::g_stop)
	{
		const arcsnd::core_name c = arcsnd::read_core_name();
		if (hornet_claims(c.name.c_str()))
		{
			if (verbose) fprintf(stderr, "arcsnd: %s, the Hornet board\n", c.name.c_str());
			hornet_run(mem, verbose);
		}
		else if (hng64_claims(c.name.c_str()))
		{
			if (verbose) fprintf(stderr, "arcsnd: %s, the hng64 board\n", c.name.c_str());
			hng64_run(mem, verbose);
		}
		else arcsnd::sleep_ns(250'000'000);
	}
	return 0;
}
