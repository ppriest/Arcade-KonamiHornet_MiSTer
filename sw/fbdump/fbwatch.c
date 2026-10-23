// SPDX-License-Identifier: GPL-3.0-or-later
// fbwatch: watch the Voodoo's two colour buffers (DDR3 0x3F400000, 384 rows of 1024 bytes, the second
// at +0x60000) for rows 352-383 that are mostly gold (the stripes), and save the whole 2 MB frame
// buffer when they appear.
//     fbwatch <out prefix> <max captures> <seconds>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static int gold_rows(const volatile uint16_t *b)
{
	int n = 0;
	for (int y = 352; y < 384; y++) {
		int g = 0;
		for (int x = 0; x < 512; x++) {
			uint16_t p = b[y * 512 + x];
			if ((p >> 11) > 20 && ((p >> 5) & 63) > 32 && (p & 31) < 12) g++;
		}
		if (g > 256) n++;
	}
	return n;
}

int main(int argc, char **argv)
{
	if (argc != 4) { fprintf(stderr, "fbwatch <out prefix> <max> <seconds>\n"); return 1; }
	int max = atoi(argv[2]), secs = atoi(argv[3]);
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return 1; }
	volatile uint8_t *fb = mmap(0, 0x200000, PROT_READ, MAP_SHARED, fd, 0x3F400000);
	if (fb == MAP_FAILED) { perror("mmap"); return 1; }
	static uint8_t copy[0x200000];
	time_t end = time(0) + secs;
	int caps = 0, polls = 0;
	while (caps < max && time(0) < end) {
		polls++;
		int g0 = gold_rows((volatile uint16_t *)fb), g1 = gold_rows((volatile uint16_t *)(fb + 0x60000));
		if (g0 >= 3 || g1 >= 3) {
			for (int i = 0; i < 0x200000; i++) copy[i] = fb[i];
			char name[256];
			snprintf(name, sizeof name, "%s%d_b%d.bin", argv[1], caps, g1 > g0);
			FILE *f = fopen(name, "wb");
			if (f) { fwrite(copy, 1, sizeof copy, f); fclose(f); }
			printf("capture %d: buffer 0 %d gold rows, buffer 1 %d\n", caps, g0, g1);
			fflush(stdout);
			caps++;
			usleep(300000);
		}
		usleep(50000);
	}
	printf("%d polls, %d captures\n", polls, caps);
	return 0;
}
