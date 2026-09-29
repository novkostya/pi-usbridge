/*
 * hapload [/dev/snd/pcmC0D0p]: stream 4-channel 48 kHz audio to a DualSense
 * like a game driving its speaker (channels 1-2) and haptics (3-4). The
 * samples are silence: the USB traffic is the same as with sound. Prints once per
 * second: <uptime> frames=<frames written/s> xruns=<underruns> err=<errors>
 * A stalled stream shows as frames=0 (the write blocks).
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <sound/asound.h>

#define RATE 48000
#define CH 4
#define PERIOD 480   /* 10 ms */

static volatile unsigned long frames, xruns, errs;

/* Report from a separate thread, so a write that blocks still shows (frames=0). */
static void *report(void *arg)
{
	(void)arg;
	for (;;) {
		sleep(1);
		struct timespec up;
		clock_gettime(CLOCK_BOOTTIME, &up);
		printf("%ld frames=%lu xruns=%lu err=%lu\n", (long)up.tv_sec, frames, xruns, errs);
		frames = xruns = errs = 0;
	}
	return NULL;
}

static void set_mask(struct snd_pcm_hw_params *p, int param, unsigned int bit)
{
	struct snd_mask *m = &p->masks[param - SNDRV_PCM_HW_PARAM_FIRST_MASK];
	memset(m, 0, sizeof(*m));
	m->bits[bit >> 5] |= 1u << (bit & 31);
}

static void set_int(struct snd_pcm_hw_params *p, int param, unsigned int val)
{
	struct snd_interval *i = &p->intervals[param - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL];
	memset(i, 0, sizeof(*i));
	i->min = i->max = val;
	i->integer = 1;
}

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/snd/pcmC0D0p";
	int fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return 1;
	}

	/* Everything allowed, then pin what we want. */
	struct snd_pcm_hw_params hw;
	memset(&hw, 0, sizeof(hw));
	for (int i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_MASK - SNDRV_PCM_HW_PARAM_FIRST_MASK; i++)
		memset(&hw.masks[i], 0xff, sizeof(hw.masks[i]));
	for (int i = 0; i <= SNDRV_PCM_HW_PARAM_LAST_INTERVAL - SNDRV_PCM_HW_PARAM_FIRST_INTERVAL; i++)
		hw.intervals[i].max = ~0u;
	hw.rmask = ~0u;
	set_mask(&hw, SNDRV_PCM_HW_PARAM_ACCESS, SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	set_mask(&hw, SNDRV_PCM_HW_PARAM_FORMAT, SNDRV_PCM_FORMAT_S16_LE);
	set_mask(&hw, SNDRV_PCM_HW_PARAM_SUBFORMAT, SNDRV_PCM_SUBFORMAT_STD);
	set_int(&hw, SNDRV_PCM_HW_PARAM_CHANNELS, CH);
	set_int(&hw, SNDRV_PCM_HW_PARAM_RATE, RATE);
	set_int(&hw, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, PERIOD);
	set_int(&hw, SNDRV_PCM_HW_PARAM_PERIODS, 8);
	if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &hw) < 0 || ioctl(fd, SNDRV_PCM_IOCTL_PREPARE) < 0) {
		perror("hw_params/prepare");
		return 1;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);

	pthread_t th;
	pthread_create(&th, NULL, report, NULL);

	static short buf[PERIOD * CH];  /* silence */
	for (;;) {
		struct snd_xferi x = { .buf = buf, .frames = PERIOD };
		if (ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &x) == 0) {
			frames += x.result;
		} else if (errno == EPIPE) {  /* underrun */
			xruns++;
			ioctl(fd, SNDRV_PCM_IOCTL_PREPARE);
		} else {
			errs++;
			usleep(10000);
		}
	}
}
