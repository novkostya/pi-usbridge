/*
 * urbstorm /dev/bus/usb/BBB/DDD [cancel_every]: drive a DualSense's HID
 * interface through usbfs like vhusbd does: an interrupt IN URB always
 * pending, 48-byte interrupt OUT reports at 250 Hz, and every Nth OUT URB
 * (and IN URB) cancelled while still pending ("abort endpoint"). Silent:
 * motors off, no trigger effects.
 * Prints once per second: <uptime> in=<IN completions> out=<OUT completions>
 * cancelled=<discards> err=<failed completions/submits>
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/usbdevice_fs.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define IFACE 3
#define EP_IN 0x84
#define EP_OUT 0x03

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static struct usbdevfs_urb urb_in, urb_out;
static unsigned char buf_in[64], buf_out[48];
static int in_busy, out_busy;

static int submit(int fd, struct usbdevfs_urb *u, unsigned char ep, void *buf, int len)
{
	memset(u, 0, sizeof(*u));
	u->type = USBDEVFS_URB_TYPE_INTERRUPT;
	u->endpoint = ep;
	u->buffer = buf;
	u->buffer_length = len;
	return ioctl(fd, USBDEVFS_SUBMITURB, u);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s /dev/bus/usb/BBB/DDD [cancel_every]\n", argv[0]);
		return 1;
	}
	int every = argc > 2 ? atoi(argv[2]) : 20;
	int fd = open(argv[1], O_RDWR);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	struct usbdevfs_disconnect_claim dc = { .interface = IFACE, .flags = USBDEVFS_DISCONNECT_CLAIM_EXCEPT_DRIVER };
	strcpy(dc.driver, "usbfs");
	if (ioctl(fd, USBDEVFS_DISCONNECT_CLAIM, &dc) < 0) {
		perror("claim interface");
		return 1;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);

	unsigned long n_in = 0, n_out = 0, n_cancel = 0, n_err = 0, seq = 0;
	double next_out = now(), next_stat = now() + 1;
	for (;;) {
		if (!in_busy) {
			if (submit(fd, &urb_in, EP_IN, buf_in, sizeof(buf_in)) == 0)
				in_busy = 1;
			else
				n_err++;
		}
		double t = now();
		if (t >= next_out && !out_busy) {
			memset(buf_out, 0, sizeof(buf_out));
			buf_out[0] = 0x02;
			buf_out[1] = 0x0f;
			buf_out[2] = 0x04;
			buf_out[47] = 0x20;  /* motors 0, no trigger effects, lightbar dim blue */
			if (submit(fd, &urb_out, EP_OUT, buf_out, sizeof(buf_out)) == 0) {
				out_busy = 1;
				seq++;
				/* vhusbd-style abort: cancel while pending */
				if (every > 0 && seq % every == 0 && ioctl(fd, USBDEVFS_DISCARDURB, &urb_out) == 0)
					n_cancel++;
				if (every > 0 && seq % (every * 3) == 0 && in_busy &&
				    ioctl(fd, USBDEVFS_DISCARDURB, &urb_in) == 0)
					n_cancel++;
			} else {
				n_err++;
			}
			next_out += 1.0 / 250;
			if (next_out < t)
				next_out = t + 1.0 / 250;
		}

		/* Reap completions (poll() reports POLLOUT when one is ready). */
		struct pollfd p = { .fd = fd, .events = POLLOUT };
		int wait = (int)((next_out - now()) * 1000);
		poll(&p, 1, wait > 0 ? wait : 0);
		struct usbdevfs_urb *done;
		while (ioctl(fd, USBDEVFS_REAPURBNDELAY, &done) == 0) {
			int ok = done->status == 0;
			if (done == &urb_in) {
				in_busy = 0;
				if (ok) n_in++;
			} else if (done == &urb_out) {
				out_busy = 0;
				if (ok) n_out++;
			}
			if (!ok && done->status != -ENOENT && done->status != -ECONNRESET)
				n_err++;
		}
		if (errno == ENODEV) {
			fprintf(stderr, "device gone\n");
			return 1;
		}

		if (now() >= next_stat) {
			struct timespec up;
			clock_gettime(CLOCK_BOOTTIME, &up);
			printf("%ld in=%lu out=%lu cancelled=%lu err=%lu\n", (long)up.tv_sec, n_in, n_out, n_cancel, n_err);
			n_in = n_out = n_cancel = n_err = 0;
			next_stat += 1;
		}
	}
}
