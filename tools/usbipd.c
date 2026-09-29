/*
 * usbipd: a minimal USB/IP server. The kernel's usbip-host driver carries the
 * USB traffic; this only answers the two requests a client makes before that
 * (list devices, import one) and hands the connection to the kernel.
 *
 *   usbipd [-p PORT] [-a ADDR[/LEN]]... [-d VID:PID]...
 *
 * Only devices matching -d are listed or exported (default: DualSense and
 * DualSense Edge), and never hubs or network adapters, so the Pi can't be cut
 * off its network. With -a, only those clients may connect; without it,
 * anyone who can reach the port. A client asking for a bus ID that isn't
 * exported gets the one exported device when exactly one is plugged in, so
 * moving it to another USB port is fine. Clients that disappear are dropped
 * within ~10 s, freeing the device.
 */
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define USBIP_VERSION 0x0111
#define OP_REQ_DEVLIST 0x8005
#define OP_REP_DEVLIST 0x0005
#define OP_REQ_IMPORT 0x8003
#define OP_REP_IMPORT 0x0003
#define ST_OK 0
#define ST_NA 1
#define ST_DEV_BUSY 2
#define ST_NODEV 4

#define SYS_DEVICES "/sys/bus/usb/devices"
#define SYS_HOST "/sys/bus/usb/drivers/usbip-host"
#define BUSID_SIZE 32
#define DEVICE_SIZE 312 /* struct usbip_usb_device */
#define TIMEOUT_MS 5000 /* for a client to send its request */

static struct { uint16_t vid, pid; } devs[16] = { { 0x054c, 0x0ce6 }, { 0x054c, 0x0df2 } };
static int ndevs = 2, devs_given;
static struct { struct in6_addr addr; int len; } allow[16];
static int nallow;

static void say(const char *fmt, ...)
{
	char line[256] = "usbipd: ";
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line + 8, sizeof(line) - 9, fmt, ap);
	va_end(ap);
	strcat(line, "\n");
	/* one write per line, so it can go to /dev/kmsg */
	if (write(2, line, strlen(line)) < 0)
		return;
}

/* read_attr BUSID NAME BUF: a sysfs attribute of a device, without the newline */
static int read_attr(const char *busid, const char *name, char *buf, size_t size)
{
	char path[PATH_MAX];
	snprintf(path, sizeof(path), SYS_DEVICES "/%s/%s", busid, name);
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	if (!fgets(buf, size, f))
		buf[0] = 0;
	fclose(f);
	buf[strcspn(buf, "\n")] = 0;
	return 0;
}

static unsigned attr(const char *busid, const char *name, int base)
{
	char buf[64];
	if (read_attr(busid, name, buf, sizeof(buf)) < 0)
		return 0;
	return strtoul(buf, NULL, base);
}

static int write_file(const char *path, const char *s)
{
	FILE *f = fopen(path, "w");
	if (!f)
		return -1;
	int ok = fputs(s, f) >= 0;
	return fclose(f) == 0 && ok ? 0 : -1;
}

/* Does BUSID carry a network interface (like the Pi's own Ethernet)? */
static int has_netdev(const char *busid)
{
	char path[PATH_MAX];
	snprintf(path, sizeof(path), SYS_DEVICES "/%s", busid);
	DIR *d = opendir(path);
	int found = 0;
	for (struct dirent *e; d && !found && (e = readdir(d));) {
		if (strncmp(e->d_name, busid, strlen(busid)) || e->d_name[strlen(busid)] != ':')
			continue;
		snprintf(path, sizeof(path), SYS_DEVICES "/%s/%s/net", busid, e->d_name);
		found = access(path, F_OK) == 0;
	}
	if (d)
		closedir(d);
	return found;
}

/* Is BUSID a device (not a root hub or an interface) we export? Never a hub
 * or a network adapter, whatever -d says: that would cut the Pi off. */
static int exported(const char *busid)
{
	if (strchr(busid, ':') || !strncmp(busid, "usb", 3) || strlen(busid) >= BUSID_SIZE)
		return 0;
	unsigned vid = attr(busid, "idVendor", 16), pid = attr(busid, "idProduct", 16);
	for (int i = 0; i < ndevs; i++)
		if (devs[i].vid == vid && devs[i].pid == pid)
			return attr(busid, "bDeviceClass", 16) != 0x09 && !has_netdev(busid);
	return 0;
}

static uint8_t *put16(uint8_t *p, unsigned v) { p[0] = v >> 8; p[1] = v; return p + 2; }
static uint8_t *put32(uint8_t *p, unsigned v) { put16(p, v >> 16); put16(p + 2, v); return p + 4; }

static unsigned speed(const char *busid)
{
	static const char *const names[] = { "unknown", "1.5", "12", "480", "53.3-480", "5000", "10000" };
	char buf[16];
	if (read_attr(busid, "speed", buf, sizeof(buf)) == 0)
		for (unsigned i = 0; i < sizeof(names) / sizeof(*names); i++)
			if (!strcmp(buf, names[i]))
				return i;
	return 0;
}

/* describe BUSID OUT: struct usbip_usb_device, then (with IFACES) one
 * struct usbip_usb_interface per interface. Returns its size. */
static size_t describe(const char *busid, uint8_t *out, int ifaces)
{
	char path[PATH_MAX], real[PATH_MAX];
	memset(out, 0, DEVICE_SIZE);
	snprintf(path, sizeof(path), SYS_DEVICES "/%s", busid);
	if (realpath(path, real))
		strncpy((char *)out, real, 255);
	snprintf((char *)out + 256, BUSID_SIZE, "%s", busid);
	uint8_t *p = out + 256 + BUSID_SIZE;
	p = put32(p, attr(busid, "busnum", 10));
	p = put32(p, attr(busid, "devnum", 10));
	p = put32(p, speed(busid));
	p = put16(p, attr(busid, "idVendor", 16));
	p = put16(p, attr(busid, "idProduct", 16));
	p = put16(p, attr(busid, "bcdDevice", 16));
	*p++ = attr(busid, "bDeviceClass", 16);
	*p++ = attr(busid, "bDeviceSubClass", 16);
	*p++ = attr(busid, "bDeviceProtocol", 16);
	unsigned config = attr(busid, "bConfigurationValue", 10);
	*p++ = config;
	*p++ = attr(busid, "bNumConfigurations", 10);
	unsigned n = config ? attr(busid, "bNumInterfaces", 10) : 0;
	if (n > 32)
		n = 32;
	*p++ = n;
	if (!ifaces)
		return DEVICE_SIZE;
	static const char *const fields[] = { "bInterfaceClass", "bInterfaceSubClass", "bInterfaceProtocol" };
	for (unsigned i = 0; i < n; i++) {
		for (int f = 0; f < 3; f++) {
			char name[BUSID_SIZE + 48];
			snprintf(name, sizeof(name), "%s:%u.%u/%s", busid, config, i, fields[f]);
			*p++ = attr(busid, name, 16);
		}
		*p++ = 0; /* padding */
	}
	return p - out;
}

static int send_all(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;
	while (len) {
		ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
		if (n <= 0)
			return -1;
		p += n;
		len -= n;
	}
	return 0;
}

static int recv_all(int fd, void *buf, size_t len)
{
	uint8_t *p = buf;
	while (len) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		if (poll(&pfd, 1, TIMEOUT_MS) != 1)
			return -1;
		ssize_t n = recv(fd, p, len, 0);
		if (n <= 0)
			return -1;
		p += n;
		len -= n;
	}
	return 0;
}

static int reply(int fd, unsigned code, unsigned status)
{
	uint8_t hdr[8];
	put32(put16(put16(hdr, USBIP_VERSION), code), status);
	return send_all(fd, hdr, sizeof(hdr));
}

/* The exported devices that are plugged in: their bus IDs, and how many. */
static int scan(char names[16][BUSID_SIZE])
{
	int n = 0;
	DIR *d = opendir(SYS_DEVICES);
	for (struct dirent *e; d && (e = readdir(d)) && n < 16;)
		if (e->d_name[0] != '.' && exported(e->d_name))
			strcpy(names[n++], e->d_name); /* exported() checked its length */
	if (d)
		closedir(d);
	return n;
}

static void devlist(int fd)
{
	char names[16][BUSID_SIZE];
	int n = scan(names);
	uint8_t buf[4 + 16 * (DEVICE_SIZE + 32 * 4)], *p = put32(buf, n);
	for (int i = 0; i < n; i++)
		p += describe(names[i], p, 1);
	if (reply(fd, OP_REP_DEVLIST, ST_OK) == 0)
		send_all(fd, buf, p - buf);
}

/* Give BUSID to usbip-host, like "usbip bind" does. */
static int bind_host(const char *busid)
{
	char path[PATH_MAX], link[PATH_MAX], cmd[BUSID_SIZE + 8];
	snprintf(path, sizeof(path), SYS_DEVICES "/%s/driver", busid);
	ssize_t n = readlink(path, link, sizeof(link) - 1);
	if (n > 0) {
		link[n] = 0;
		if (!strcmp(strrchr(link, '/') + 1, "usbip-host"))
			return 0;
		snprintf(path, sizeof(path), SYS_DEVICES "/%s/driver/unbind", busid);
		if (write_file(path, busid) < 0)
			return -1;
	}
	snprintf(cmd, sizeof(cmd), "add %s", busid);
	if (write_file(SYS_HOST "/match_busid", cmd) < 0)
		return -1;
	return write_file(SYS_HOST "/bind", busid);
}

static void import(int fd, const char *peer)
{
	char busid[BUSID_SIZE + 1] = "", asked[BUSID_SIZE + 1], path[PATH_MAX], buf[16];
	if (recv_all(fd, busid, BUSID_SIZE) < 0)
		return;
	busid[BUSID_SIZE] = 0;
	strcpy(asked, busid);
	if (!exported(busid)) {
		/* Clients remember the bus ID, which changes with the USB port.
		 * With one exported device plugged in, serve it whatever they ask. */
		char names[16][BUSID_SIZE];
		if (scan(names) != 1) {
			say("%s asked for %s: not exported", peer, busid);
			reply(fd, OP_REP_IMPORT, ST_NODEV);
			return;
		}
		say("%s asked for %s, serving %s", peer, busid, names[0]);
		strcpy(busid, names[0]);
	}
	if (bind_host(busid) < 0) {
		say("%s: can't bind %s to usbip-host: %s", peer, busid, strerror(errno));
		reply(fd, OP_REP_IMPORT, ST_NA);
		return;
	}
	if (read_attr(busid, "usbip_status", buf, sizeof(buf)) < 0 || strcmp(buf, "1")) {
		say("%s asked for %s: in use", peer, busid);
		reply(fd, OP_REP_IMPORT, ST_DEV_BUSY);
		return;
	}
	/* Low latency; drop a client whose data goes unacknowledged for 10 s
	 * (or who goes silent for 11), so the device doesn't stay taken. */
	int one = 1, idle = 5, intvl = 2, cnt = 3;
	unsigned user_timeout = 10000;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
	setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
	setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
	setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
	setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, &user_timeout, sizeof(user_timeout));
	uint8_t dev[DEVICE_SIZE];
	describe(busid, dev, 0);
	/* Clients check that the reply names the bus ID they asked for. */
	memset(dev + 256, 0, BUSID_SIZE);
	memcpy(dev + 256, asked, strlen(asked));
	if (reply(fd, OP_REP_IMPORT, ST_OK) < 0 || send_all(fd, dev, sizeof(dev)) < 0)
		return;
	snprintf(path, sizeof(path), SYS_DEVICES "/%s/usbip_sockfd", busid);
	snprintf(buf, sizeof(buf), "%d", fd);
	if (write_file(path, buf) < 0)
		say("%s: handing %s over failed: %s", peer, busid, strerror(errno));
	else
		say("%s attached %s", peer, busid);
}

static int allowed(const struct in6_addr *a)
{
	if (!nallow)
		return 1;
	for (int i = 0; i < nallow; i++) {
		int bits = allow[i].len, j = 0;
		for (; bits >= 8; j++, bits -= 8)
			if (a->s6_addr[j] != allow[i].addr.s6_addr[j])
				break;
		if (bits < 8 && (!bits || !((a->s6_addr[j] ^ allow[i].addr.s6_addr[j]) & (0xff00 >> bits))))
			return 1;
	}
	return 0;
}

/* ADDR[/LEN], IPv4 or IPv6; IPv4 is kept as ::ffff:a.b.c.d */
static int parse_allow(const char *s)
{
	char a[64];
	snprintf(a, sizeof(a), "%s", s);
	char *slash = strchr(a, '/');
	int len = -1;
	if (slash) {
		*slash = 0;
		len = atoi(slash + 1);
	}
	struct in6_addr *x = &allow[nallow].addr;
	struct in_addr v4;
	if (inet_pton(AF_INET, a, &v4) == 1) {
		memset(x, 0, sizeof(*x));
		x->s6_addr[10] = x->s6_addr[11] = 0xff;
		memcpy(&x->s6_addr[12], &v4, 4);
		len = len < 0 ? 128 : 96 + len;
	} else if (inet_pton(AF_INET6, a, x) != 1) {
		return -1;
	} else if (len < 0) {
		len = 128;
	}
	if (len > 128 || len < 0)
		return -1;
	allow[nallow++].len = len;
	return 0;
}

int main(int argc, char **argv)
{
	int port = 3240, opt;
	while ((opt = getopt(argc, argv, "p:a:d:")) != -1) {
		if (opt == 'p') {
			port = atoi(optarg);
		} else if (opt == 'a' && nallow < 16) {
			if (parse_allow(optarg) < 0) {
				fprintf(stderr, "bad address: %s\n", optarg);
				return 1;
			}
		} else if (opt == 'd' && ndevs < 16) {
			unsigned vid, pid;
			if (sscanf(optarg, "%x:%x", &vid, &pid) != 2) {
				fprintf(stderr, "bad device: %s\n", optarg);
				return 1;
			}
			if (!devs_given++)
				ndevs = 0;
			devs[ndevs].vid = vid;
			devs[ndevs++].pid = pid;
		} else {
			fprintf(stderr, "usage: %s [-p PORT] [-a ADDR[/LEN]]... [-d VID:PID]...\n", argv[0]);
			return 1;
		}
	}
	signal(SIGPIPE, SIG_IGN);

	int s = socket(AF_INET6, SOCK_STREAM, 0), zero = 0, one = 1;
	struct sockaddr_in6 sa = { .sin6_family = AF_INET6, .sin6_port = htons(port), .sin6_addr = IN6ADDR_ANY_INIT };
	struct sockaddr_in sa4 = { .sin_family = AF_INET, .sin_port = htons(port) };
	if (s >= 0) {
		setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &zero, sizeof(zero));
		setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
			close(s);
			s = -1;
		}
	}
	if (s < 0) { /* no IPv6 */
		s = socket(AF_INET, SOCK_STREAM, 0);
		setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
		if (s < 0 || bind(s, (struct sockaddr *)&sa4, sizeof(sa4)) < 0) {
			perror("bind");
			return 1;
		}
	}
	if (listen(s, 4) < 0) {
		perror("listen");
		return 1;
	}
	if (access(SYS_HOST, F_OK) < 0)
		say("warning: the usbip-host driver isn't loaded");
	say("listening on port %d", port);

	for (;;) {
		struct sockaddr_storage peer;
		socklen_t plen = sizeof(peer);
		int fd = accept(s, (struct sockaddr *)&peer, &plen);
		if (fd < 0)
			continue;
		struct in6_addr a;
		char name[INET6_ADDRSTRLEN] = "?";
		if (peer.ss_family == AF_INET6) {
			a = ((struct sockaddr_in6 *)&peer)->sin6_addr;
		} else {
			memset(&a, 0, sizeof(a));
			a.s6_addr[10] = a.s6_addr[11] = 0xff;
			memcpy(&a.s6_addr[12], &((struct sockaddr_in *)&peer)->sin_addr, 4);
		}
		if (IN6_IS_ADDR_V4MAPPED(&a))
			inet_ntop(AF_INET, &a.s6_addr[12], name, sizeof(name));
		else
			inet_ntop(AF_INET6, &a, name, sizeof(name));

		uint8_t hdr[8];
		if (!allowed(&a)) {
			say("refused %s", name);
		} else if (recv_all(fd, hdr, sizeof(hdr)) == 0) {
			unsigned code = hdr[2] << 8 | hdr[3];
			if (code == OP_REQ_DEVLIST)
				devlist(fd);
			else if (code == OP_REQ_IMPORT)
				import(fd, name);
			else
				say("%s: unknown request %04x", name, code);
		}
		close(fd);
	}
}
