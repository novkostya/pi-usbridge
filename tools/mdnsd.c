/*
 * mdnsd: answers multicast DNS (RFC 6762) queries for HOSTNAME.local with
 * IFACE's IPv4 address, so PCs find the Pi as e.g. usbridge.local on any
 * network: behind any router, or on a direct cable with link-local
 * addresses. Nothing else: no services, no probing or announcing.
 *
 *   mdnsd [-v] IFACE      (-v: log every query for us to stderr)
 *
 * The name is the system hostname and the address is looked up for every
 * answer, so both may change while it runs (DHCP, link-local fallback).
 */
#include <arpa/inet.h>
#include <ctype.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#define PORT 5353
#define TYPE_A 1
#define TYPE_NSEC 47
#define TYPE_AAAA 28
#define TYPE_ANY 255

static const char *iface;
static int verbose;

/* name_at MSG LEN POS OUT: decode the (possibly compressed) name at POS into
 * dotted form; returns the position after it in the message, or -1. */
static int name_at(const uint8_t *msg, int len, int pos, char *out, size_t size)
{
	int end = -1, hops = 0;
	size_t n = 0;
	while (pos < len) {
		uint8_t l = msg[pos];
		if (l == 0) {
			out[n] = 0;
			return end < 0 ? pos + 1 : end;
		}
		if ((l & 0xc0) == 0xc0) { /* compression pointer */
			if (pos + 1 >= len || ++hops > 16)
				return -1;
			if (end < 0)
				end = pos + 2;
			pos = (l & 0x3f) << 8 | msg[pos + 1];
			continue;
		}
		if (pos + 1 + l > len || n + l + 2 > size)
			return -1;
		if (n)
			out[n++] = '.';
		memcpy(out + n, msg + pos + 1, l);
		n += l;
		pos += 1 + l;
	}
	return -1;
}

static int our_address(struct in_addr *a)
{
	struct ifreq ifr = { 0 };
	int s = socket(AF_INET, SOCK_DGRAM, 0), ok;
	snprintf(ifr.ifr_name, IFNAMSIZ, "%s", iface);
	ok = s >= 0 && ioctl(s, SIOCGIFADDR, &ifr) == 0;
	if (s >= 0)
		close(s);
	if (ok)
		*a = ((struct sockaddr_in *)&ifr.ifr_addr)->sin_addr;
	return ok ? 0 : -1;
}

static uint8_t *put16(uint8_t *p, unsigned v) { p[0] = v >> 8; p[1] = v; return p + 2; }

/* NAME in DNS wire format: "usbridge.local" -> 8usbridge5local0 */
static uint8_t *put_name(uint8_t *p, const char *name)
{
	while (*name) {
		const char *dot = strchr(name, '.');
		size_t l = dot ? (size_t)(dot - name) : strlen(name);
		*p++ = l;
		memcpy(p, name, l);
		p += l;
		name += l + (dot != NULL);
	}
	*p++ = 0;
	return p;
}

int main(int argc, char **argv)
{
	if (argc == 3 && !strcmp(argv[1], "-v")) {
		verbose = 1;
		argv++, argc--;
	}
	if (argc != 2) {
		fprintf(stderr, "usage: %s [-v] IFACE\n", argv[0]);
		return 1;
	}
	iface = argv[1];
	int s = socket(AF_INET, SOCK_DGRAM, 0), one = 1, ttl = 255, zero = 0;
	struct sockaddr_in any = { .sin_family = AF_INET, .sin_port = htons(PORT) };
	struct ip_mreqn mreq = { .imr_ifindex = if_nametoindex(iface) };
	inet_pton(AF_INET, "224.0.0.251", &mreq.imr_multiaddr);
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one));
	if (bind(s, (struct sockaddr *)&any, sizeof(any)) < 0 ||
	    setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0 ||
	    setsockopt(s, IPPROTO_IP, IP_MULTICAST_IF, &mreq, sizeof(mreq)) < 0) {
		perror("mdnsd");
		return 1;
	}
	setsockopt(s, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));
	setsockopt(s, IPPROTO_IP, IP_MULTICAST_LOOP, &zero, sizeof(zero));

	for (;;) {
		uint8_t msg[1500], out[512];
		struct sockaddr_in from;
		socklen_t flen = sizeof(from);
		int len = recvfrom(s, msg, sizeof(msg), 0, (struct sockaddr *)&from, &flen);
		if (len < 12 || msg[2] & 0x80) /* too short, or a response */
			continue;
		char host[64], want[80], name[256];
		gethostname(host, sizeof(host));
		host[sizeof(host) - 1] = 0;
		snprintf(want, sizeof(want), "%s.local", host);

		int qdcount = msg[4] << 8 | msg[5], pos = 12, want_a = 0, want_aaaa = 0, first = 0;
		for (int i = 0; i < qdcount && pos > 0; i++) {
			pos = name_at(msg, len, pos, name, sizeof(name));
			if (pos < 0 || pos + 4 > len)
				break;
			int t = msg[pos] << 8 | msg[pos + 1], qu = msg[pos + 2] & 0x80;
			pos += 4;
			if (strcasecmp(name, want))
				continue;
			if (verbose)
				fprintf(stderr, "mdnsd: %s:%d asks type %d%s (%d questions)\n",
					inet_ntoa(from.sin_addr), ntohs(from.sin_port), t, qu ? " QU" : "", qdcount);
			if (t == TYPE_A || t == TYPE_ANY)
				want_a = 1;
			else if (t == TYPE_AAAA)
				want_aaaa = 1;
			else
				continue;
			if (!first)
				first = t;
		}
		struct in_addr addr;
		if (!first || our_address(&addr) < 0)
			continue;

		/* A query from a port other than 5353 is a plain DNS resolver ("legacy
		 * unicast", RFC 6762 6.7): answer it directly, echoing its ID and
		 * question. Otherwise answer on the multicast group. */
		int legacy = ntohs(from.sin_port) != PORT;
		unsigned class = legacy ? 1 : 0x8001; /* IN, plus cache-flush for mDNS */
		unsigned ttl = legacy ? 10 : 120;
		/* Asked for A: answer it, and add an NSEC saying there's no AAAA.
		 * Asked for AAAA only: answer the NSEC, and add the A. (RFC 6762
		 * 6.1, 6.2; without the NSEC, Windows waits ~2.5 s for an AAAA.) */
		int nsec_answer = want_aaaa && !want_a;
		uint8_t *p = out;
		p = put16(p, legacy ? (msg[0] << 8 | msg[1]) : 0);
		p = put16(p, 0x8400); /* response, authoritative */
		p = put16(p, legacy);
		p = put16(p, 1 + (want_a && want_aaaa));
		p = put16(p, 0);
		p = put16(p, !(want_a && want_aaaa));
		if (legacy) {
			p = put_name(p, want);
			p = put16(p, first);
			p = put16(p, 1);
		}
		uint8_t *owner = p;
		p = put_name(p, want);
		for (int rr = 0; rr < 2; rr++) {
			if (rr) /* the same name again, as a pointer */
				p = put16(p, 0xc000 | (owner - out));
			if ((rr == 0) != nsec_answer) {
				p = put16(p, TYPE_A);
				p = put16(p, class);
				p = put16(p, 0), p = put16(p, ttl);
				p = put16(p, 4);
				memcpy(p, &addr, 4);
				p += 4;
			} else {
				p = put16(p, TYPE_NSEC);
				p = put16(p, class);
				p = put16(p, 0), p = put16(p, ttl);
				p = put16(p, 2 + 3);
				p = put16(p, 0xc000 | (owner - out)); /* next name: itself */
				*p++ = 0, *p++ = 1, *p++ = 0x40;      /* window 0, 1 byte: A only */
			}
		}
		struct sockaddr_in to = from;
		if (!legacy) {
			inet_pton(AF_INET, "224.0.0.251", &to.sin_addr);
			to.sin_port = htons(PORT);
		}
		sendto(s, out, p - out, 0, (struct sockaddr *)&to, sizeof(to));
	}
}
