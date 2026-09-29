/* Print the firmware's throttled flags, like `vcgencmd get_throttled`. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define IOCTL_MBOX_PROPERTY _IOWR(100, 0, char *)

int main(void)
{
	uint32_t msg[7] __attribute__((aligned(16))) = {
		sizeof(msg), 0,          /* size, request */
		0x00030046, 4, 0, 0,     /* GET_THROTTLED tag, buf size, req, value */
		0,                       /* end tag */
	};
	int fd = open("/dev/vcio", O_RDWR);
	if (fd < 0 || ioctl(fd, IOCTL_MBOX_PROPERTY, msg) < 0) {
		perror("vcio");
		return 1;
	}
	if (msg[1] != 0x80000000 || !(msg[4] & 0x80000000)) {
		fprintf(stderr, "firmware did not answer (0x%x 0x%x)\n", msg[1], msg[4]);
		return 1;
	}
	printf("throttled=0x%x\n", msg[5]);
	return 0;
}
