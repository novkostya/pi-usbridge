/*
 * dsload HIDRAW [RATE_HZ]: load a DualSense like a game does. Writes USB
 * output report 0x02 (rumble motors, adaptive trigger effects, lightbar) at
 * RATE_HZ, reads input reports, and prints one line per second:
 * The reports are silent: motors off, triggers without effect, lightbar
 * steady. The USB traffic is the same as with a game shaking it.
 *   <uptime> in=<input reports/s> out=<output reports/s> werr=<write errors>
 * A falling "in" rate means the controller (or the USB bus) is stalling.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s /dev/hidrawN [rate_hz]\n", argv[0]);
		return 1;
	}
	int rate = argc > 2 ? atoi(argv[2]) : 250;
	int fd = open(argv[1], O_RDWR | O_NONBLOCK);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);

	unsigned char in[128], out[48];
	unsigned long n_in = 0, n_out = 0, n_err = 0;
	double interval = 1.0 / rate, next_out = now(), next_stat = now() + 1;

	for (;;) {
		double t = now();
		int timeout = (int)((next_out - t) * 1000);
		struct pollfd p = { .fd = fd, .events = POLLIN };
		if (poll(&p, 1, timeout > 0 ? timeout : 0) > 0 && (p.revents & POLLIN))
			while (read(fd, in, sizeof(in)) > 0)
				n_in++;

		t = now();
		if (t >= next_out) {
			memset(out, 0, sizeof(out));
			out[0] = 0x02;          /* USB output report */
			out[1] = 0x0f;          /* valid: rumble, haptics, both trigger effects */
			out[2] = 0x04;          /* valid: lightbar */
			/* motors 0, trigger effects "off" (mode 0), lightbar dim blue */
			out[47] = 0x20;
			if (write(fd, out, sizeof(out)) == sizeof(out))
				n_out++;
			else if (errno != EAGAIN)
				n_err++;
			next_out += interval;
			if (next_out < t)
				next_out = t + interval;  /* fell behind, don't burst */
		}

		if (t >= next_stat) {
			struct timespec up;
			clock_gettime(CLOCK_BOOTTIME, &up);
			printf("%ld in=%lu out=%lu werr=%lu\n", (long)up.tv_sec, n_in, n_out, n_err);
			n_in = n_out = n_err = 0;
			next_stat += 1;
		}
	}
}
