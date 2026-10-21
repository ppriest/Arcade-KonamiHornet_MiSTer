// SPDX-License-Identifier: GPL-3.0-or-later
// MAME's logerror for the ported devices (mame_shim.h): to stderr when ARCSND_LOG is set.
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include "mame_shim.h"

void logerror(const char *fmt, ...)
{
	static const bool on = getenv("ARCSND_LOG") != nullptr;
	if (!on) return;
	va_list a;
	va_start(a, fmt);
	vfprintf(stderr, fmt, a);
	va_end(a);
}
