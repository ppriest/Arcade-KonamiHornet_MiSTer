// SPDX-License-Identifier: GPL-3.0-or-later
// fbdump: a physical address range (DDR3) to a file, for reading the core's memories in place.
//     fbdump <phys hex> <bytes hex> <out file>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc != 4) { fprintf(stderr, "fbdump <phys hex> <bytes hex> <out>\n"); return 1; }
	unsigned long addr = strtoul(argv[1], 0, 16), len = strtoul(argv[2], 0, 16);
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return 1; }
	unsigned long base = addr & ~0xFFFUL, off = addr - base;
	void *p = mmap(0, len + off, PROT_READ, MAP_SHARED, fd, base);
	if (p == MAP_FAILED) { perror("mmap"); return 1; }
	FILE *f = fopen(argv[3], "wb");
	if (!f) { perror(argv[3]); return 1; }
	fwrite((char *)p + off, 1, len, f);
	fclose(f);
	return 0;
}
