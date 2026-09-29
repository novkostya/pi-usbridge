/* reboot(2) with an argument, e.g. "0 tryboot" for the Raspberry Pi firmware. */
#include <linux/reboot.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s ARG\n", argv[0]);
		return 1;
	}
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, argv[1]);
	perror("reboot");
	return 1;
}
