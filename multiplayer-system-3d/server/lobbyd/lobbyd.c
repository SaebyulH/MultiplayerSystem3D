/*
 * lobbyd — small C lobby + match allocator/supervisor for
 * multiplayer-system-3d.
 *
 * Responsibilities (control plane only, never gameplay):
 *   - HTTP/1.1 JSON lobby: health, server browser, create, join, leave.
 *   - Short join codes.
 *   - UDP port allocation from a fixed range.
 *   - Spawn one headless Godot process per match and reap it.
 *   - HMAC-SHA256 join grants (same secret is passed to the match server).
 *
 * It does NOT simulate, relay, or inspect gameplay.  Gameplay is direct
 * ENet/UDP between the client and the match server.
 *
 * Build:   make
 * Run:     ./lobbyd --port 18080 --godot /mnt/c/tools/godot/godot_console.exe \
 *                     --project C:/Users/.../multiplayer-system-3d
 *
 * Docs: docs/07-dedicated-server.md
 */

#include "sha256.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_MATCHES 32
#define CODE_LEN 5
#define MAX_PLAYERS 16
#define GRANT_TTL_SECONDS 900
#define UDP_PORT_MIN 7000
#define UDP_PORT_MAX 7019
#define REQ_MAX 8192
#define RESP_MAX (32 * 1024)
#define SECRET_MAX 128
#define PATH_MAX_ARG 512
#define HOST_MAX 64
#define LOG_DIR_MAX 256

typedef struct {
	int used;
	uint64_t id;
	char code[CODE_LEN + 1];
	int udp_port;
	pid_t pid;
	time_t created;
	int players;
	int max_players;
	int state; /* 0 = staging, 1 = closed */
} match_t;

static match_t g_matches[MAX_MATCHES];
static uint64_t g_next_match_id = 1;

static char g_bind[HOST_MAX] = "127.0.0.1";
static int g_http_port = 18080;
static char g_advertise[HOST_MAX] = "127.0.0.1";
static char g_secret[SECRET_MAX] = "";
static char g_godot[PATH_MAX_ARG] = "";
static char g_project[PATH_MAX_ARG] = "";
static char g_log_dir[LOG_DIR_MAX] = "/tmp";
static int g_no_spawn = 0;
static volatile sig_atomic_t g_stop = 0;

static const char *const CODE_ALPHABET =
	"0123456789ABCDEFGHJKMNPQRSTVWXYZ"; /* Crockford base32, 32 chars */
static const char *const B64URL =
	"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/* ------------------------------------------------------------------ util */

static void logmsg(const char *fmt, ...)
{
	time_t now = time(NULL);
	struct tm tm;
	localtime_r(&now, &tm);
	char stamp[32];
	strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tm);
	fprintf(stderr, "[%s] ", stamp);
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

static void on_signal(int sig)
{
	(void)sig;
	g_stop = 1;
}

static int random_bytes(uint8_t *out, size_t len)
{
	int fd = open("/dev/urandom", O_RDONLY);
	if (fd >= 0) {
		size_t got = 0;
		while (got < len) {
			ssize_t n = read(fd, out + got, len - got);
			if (n <= 0)
				break;
			got += (size_t)n;
		}
		close(fd);
		if (got == len)
			return 0;
	}
	/* Fallback: only for a machine without /dev/urandom. */
	for (size_t i = 0; i < len; i++)
		out[i] = (uint8_t)(rand() & 0xff);
	return 0;
}

static void random_hex(char *out, size_t hex_chars)
{
	uint8_t raw[16];
	size_t bytes = (hex_chars + 1) / 2;
	if (bytes > sizeof(raw))
		bytes = sizeof(raw);
	random_bytes(raw, bytes);
	static const char *hex = "0123456789abcdef";
	for (size_t i = 0; i < hex_chars; i++) {
		uint8_t b = raw[i / 2];
		out[i] = (i % 2 == 0) ? hex[b >> 4] : hex[b & 0xf];
	}
	out[hex_chars] = '\0';
}

static size_t b64url_encode(const uint8_t *data, size_t len, char *out, size_t cap)
{
	size_t o = 0;
	for (size_t i = 0; i < len; i += 3) {
		uint32_t v = (uint32_t)data[i] << 16;
		if (i + 1 < len)
			v |= (uint32_t)data[i + 1] << 8;
		if (i + 2 < len)
			v |= data[i + 2];
		int n = (i + 2 < len) ? 4 : (i + 1 < len ? 3 : 2);
		for (int j = 0; j < n; j++) {
			if (o + 1 >= cap)
				return 0;
			out[o++] = B64URL[(v >> (18 - 6 * j)) & 0x3f];
		}
	}
	if (o >= cap)
		return 0;
	out[o] = '\0';
	return o;
}

static int appendf(char *buf, size_t cap, size_t *len, const char *fmt, ...)
{
	if (*len >= cap)
		return -1;
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(buf + *len, cap - *len, fmt, ap);
	va_end(ap);
	if (n < 0)
		return -1;
	if ((size_t)n >= cap - *len)
		return -1;
	*len += (size_t)n;
	return 0;
}

static void send_all(int fd, const char *data, size_t len)
{
	size_t sent = 0;
	while (sent < len) {
		ssize_t n = send(fd, data + sent, len - sent, MSG_NOSIGNAL);
		if (n <= 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		sent += (size_t)n;
	}
}

static void respond(int fd, int status, const char *content_type, const char *body)
{
	const char *reason = "OK";
	switch (status) {
	case 200: reason = "OK"; break;
	case 201: reason = "Created"; break;
	case 204: reason = "No Content"; break;
	case 400: reason = "Bad Request"; break;
	case 404: reason = "Not Found"; break;
	case 405: reason = "Method Not Allowed"; break;
	case 409: reason = "Conflict"; break;
	case 503: reason = "Service Unavailable"; break;
	default: reason = "Error"; break;
	}
	char header[512];
	int hlen = snprintf(header, sizeof(header),
		"HTTP/1.1 %d %s\r\n"
		"Content-Type: %s\r\n"
		"Content-Length: %zu\r\n"
		"Cache-Control: no-store\r\n"
		"Connection: close\r\n\r\n",
		status, reason, content_type, body ? strlen(body) : 0);
	if (hlen > 0)
		send_all(fd, header, (size_t)hlen);
	if (body && *body)
		send_all(fd, body, strlen(body));
}

/* ------------------------------------------------------------------ match */

static int live_matches(void)
{
	int n = 0;
	for (int i = 0; i < MAX_MATCHES; i++)
		if (g_matches[i].used)
			n++;
	return n;
}

static match_t *find_by_code(const char *code)
{
	for (int i = 0; i < MAX_MATCHES; i++) {
		if (g_matches[i].used && strcasecmp(g_matches[i].code, code) == 0)
			return &g_matches[i];
	}
	return NULL;
}

static match_t *find_by_id(uint64_t id)
{
	for (int i = 0; i < MAX_MATCHES; i++) {
		if (g_matches[i].used && g_matches[i].id == id)
			return &g_matches[i];
	}
	return NULL;
}

static int port_in_use(int port)
{
	for (int i = 0; i < MAX_MATCHES; i++) {
		if (g_matches[i].used && g_matches[i].udp_port == port)
			return 1;
	}
	return 0;
}

static int alloc_udp_port(void)
{
	for (int p = UDP_PORT_MIN; p <= UDP_PORT_MAX; p++) {
		if (!port_in_use(p))
			return p;
	}
	return -1;
}

/* Is `port` bound by any process?  Reads /proc/net/udp{,6}; if neither file
 * can be opened, assume ready rather than blocking create forever. */
static int udp_port_bound_file(const char *path, int port)
{
	FILE *f = fopen(path, "r");
	if (!f)
		return -1;
	char want[8];
	snprintf(want, sizeof(want), "%04X", port);
	char line[512];
	int bound = 0;
	/* Skip the header. */
	if (!fgets(line, sizeof(line), f)) {
		fclose(f);
		return 0;
	}
	while (fgets(line, sizeof(line), f)) {
		unsigned sl;
		char local[80], rem[80];
		if (sscanf(line, "%u: %79s %79s", &sl, local, rem) != 3)
			continue;
		char *colon = strrchr(local, ':');
		if (colon && strcasecmp(colon + 1, want) == 0) {
			bound = 1;
			break;
		}
	}
	fclose(f);
	return bound;
}

static int udp_port_bound(int port)
{
	int v4 = udp_port_bound_file("/proc/net/udp", port);
	if (v4 > 0)
		return 1;
	int v6 = udp_port_bound_file("/proc/net/udp6", port);
	if (v6 > 0)
		return 1;
	if (v4 < 0 && v6 < 0)
		return 1;
	return 0;
}

/* create must not answer before the child owns its UDP port: the client
 * connects immediately and a missed first attempt is not retried. */
static int wait_for_udp_bound(int port, pid_t pid, int timeout_ms)
{
	int waited = 0;
	while (waited < timeout_ms) {
		if (udp_port_bound(port))
			return 1;
		if (pid > 0 && kill(pid, 0) != 0 && errno == ESRCH)
			return 0;
		usleep(50 * 1000);
		waited += 50;
	}
	return udp_port_bound(port);
}

static void make_code(char *out)
{
	for (;;) {
		char candidate[CODE_LEN + 1];
		uint8_t raw[CODE_LEN];
		random_bytes(raw, sizeof(raw));
		for (int i = 0; i < CODE_LEN; i++)
			candidate[i] = CODE_ALPHABET[raw[i] & 31];
		candidate[CODE_LEN] = '\0';
		/* `out` may be the slot's own code buffer; only copy once unique. */
		if (find_by_code(candidate) == NULL) {
			memcpy(out, candidate, sizeof(candidate));
			return;
		}
	}
}

/* Payload: {"v":1,"m":<id>,"p":0,"e":<exp>,"h":<0|1>,"n":"<nonce>"}.
 * `h` is the room-host claim: 1 only on the grant returned by create. */
static int make_grant(uint64_t match_id, int is_host, char *out, size_t cap)
{
	char nonce[17];
	random_hex(nonce, 16);
	char payload[160];
	int n = snprintf(payload, sizeof(payload),
		"{\"v\":1,\"m\":%llu,\"p\":0,\"e\":%lld,\"h\":%d,\"n\":\"%s\"}",
		(unsigned long long)match_id,
		(long long)time(NULL) + GRANT_TTL_SECONDS, is_host ? 1 : 0,
		nonce);
	if (n <= 0 || (size_t)n >= sizeof(payload))
		return -1;

	char payload_b64[256];
	if (b64url_encode((const uint8_t *)payload, (size_t)n, payload_b64,
			sizeof(payload_b64)) == 0)
		return -1;

	uint8_t sig[32];
	hmac_sha256((const uint8_t *)g_secret, strlen(g_secret),
		(const uint8_t *)payload_b64, strlen(payload_b64), sig);
	char sig_b64[64];
	if (b64url_encode(sig, sizeof(sig), sig_b64, sizeof(sig_b64)) == 0)
		return -1;

	int written = snprintf(out, cap, "%s.%s", payload_b64, sig_b64);
	return (written > 0 && (size_t)written < cap) ? 0 : -1;
}

static void spawn_match(match_t *m)
{
	m->pid = 0;
	if (g_no_spawn) {
		logmsg("match %llu: --no-spawn, not starting a server",
			(unsigned long long)m->id);
		return;
	}
	if (g_godot[0] == '\0') {
		logmsg("match %llu: no --godot command configured; lobby-only",
			(unsigned long long)m->id);
		return;
	}

	char port_arg[32];
	char id_arg[48];
	char secret_arg[SECRET_MAX + 32];
	snprintf(port_arg, sizeof(port_arg), "--port=%d", m->udp_port);
	snprintf(id_arg, sizeof(id_arg), "--match-id=%llu",
		(unsigned long long)m->id);
	/*
	 * WSL interop does not translate MATCH_SECRET into the Windows child's
	 * environment, so the secret is also passed on argv for the dev path.
	 * argv is visible in the process list; P5/P6 should move this to the
	 * control channel or a secret file.
	 */
	snprintf(secret_arg, sizeof(secret_arg), "--match-secret=%s", g_secret);

	pid_t pid = fork();
	if (pid < 0) {
		logmsg("match %llu: fork failed: %s", (unsigned long long)m->id,
			strerror(errno));
		return;
	}
	if (pid == 0) {
		setsid();
		/*
		 * Do not leak the supervisor's listening/control fds into the match
		 * server.  Without this the child keeps port 18080 (and the accepted
		 * client sockets) open after lobbyd exits, so a new lobbyd cannot bind.
		 */
		for (int fd = 3; fd < 1024; fd++)
			close(fd);

		char log_path[LOG_DIR_MAX + 64];
		snprintf(log_path, sizeof(log_path), "%s/match-%llu.log", g_log_dir,
			(unsigned long long)m->id);
		int log_fd = open(log_path, O_CREAT | O_WRONLY | O_APPEND, 0644);
		if (log_fd >= 0) {
			dup2(log_fd, STDOUT_FILENO);
			dup2(log_fd, STDERR_FILENO);
			if (log_fd > STDERR_FILENO)
				close(log_fd);
		}

		setenv("MATCH_SECRET", g_secret, 1);
		char id_env[32];
		snprintf(id_env, sizeof(id_env), "%llu",
			(unsigned long long)m->id);
		setenv("MATCH_ID", id_env, 1);

		char *argv[12];
		int a = 0;
		argv[a++] = g_godot;
		if (g_project[0] != '\0') {
			argv[a++] = "--path";
			argv[a++] = g_project;
		}
		argv[a++] = "--headless";
		argv[a++] = "--";
		argv[a++] = "--server";
		argv[a++] = port_arg;
		argv[a++] = id_arg;
		argv[a++] = secret_arg;
		argv[a] = NULL;

		execv(g_godot, argv);
		_exit(127);
	}

	m->pid = pid;
	logmsg("match %llu (code %s): spawned pid %d on udp %d",
		(unsigned long long)m->id, m->code, (int)pid, m->udp_port);
}

static void reap_children(void)
{
	for (;;) {
		int status = 0;
		pid_t pid = waitpid(-1, &status, WNOHANG);
		if (pid <= 0)
			return;
		for (int i = 0; i < MAX_MATCHES; i++) {
			if (!g_matches[i].used || g_matches[i].pid != pid)
				continue;
			logmsg("match %llu (code %s): pid %d exited (%s %d); freeing",
				(unsigned long long)g_matches[i].id, g_matches[i].code,
				(int)pid,
				WIFSIGNALED(status) ? "signal" : "status",
				WIFSIGNALED(status) ? WTERMSIG(status) : WEXITSTATUS(status));
			g_matches[i].used = 0;
			g_matches[i].pid = 0;
			break;
		}
	}
}

static void stop_children(void)
{
	int remaining = 0;
	for (int i = 0; i < MAX_MATCHES; i++) {
		if (g_matches[i].used && g_matches[i].pid > 0) {
			kill(g_matches[i].pid, SIGTERM);
			remaining++;
		}
	}
	if (remaining == 0)
		return;
	logmsg("shutting down: SIGTERM to %d match process(es)", remaining);
	for (int waited = 0; waited < 50; waited++) {
		usleep(100 * 1000);
		reap_children();
		if (live_matches() == 0)
			return;
	}
	for (int i = 0; i < MAX_MATCHES; i++) {
		if (g_matches[i].used && g_matches[i].pid > 0)
			kill(g_matches[i].pid, SIGKILL);
	}
	logmsg("shutting down: SIGKILL sent to remaining matches");
}

/* --------------------------------------------------------------- handlers */

static int create_match(char *resp, size_t cap)
{
	int slot = -1;
	for (int i = 0; i < MAX_MATCHES; i++) {
		if (!g_matches[i].used) {
			slot = i;
			break;
		}
	}
	if (slot < 0)
		return 503;
	int udp = alloc_udp_port();
	if (udp < 0)
		return 503;

	match_t *m = &g_matches[slot];
	memset(m, 0, sizeof(*m));
	m->used = 1;
	m->id = g_next_match_id++;
	m->udp_port = udp;
	m->created = time(NULL);
	m->players = 1;
	m->max_players = MAX_PLAYERS;
	m->state = 0;
	make_code(m->code);

	char grant[512];
	if (make_grant(m->id, 1, grant, sizeof(grant)) != 0) {
		m->used = 0;
		return 503;
	}

	spawn_match(m);
	if (!g_no_spawn && g_godot[0] != '\0') {
		if (m->pid <= 0) {
			logmsg("match %llu: spawn failed; freeing slot",
				(unsigned long long)m->id);
			m->used = 0;
			return 503;
		}
		if (!wait_for_udp_bound(m->udp_port, m->pid, 12000)) {
			logmsg("match %llu: pid %d did not bind udp %d; killing",
				(unsigned long long)m->id, (int)m->pid, m->udp_port);
			kill(m->pid, SIGTERM);
			m->pid = 0;
			m->used = 0;
			return 503;
		}
	}

	size_t len = 0;
	appendf(resp, cap, &len,
		"{\"match_id\":%llu,\"code\":\"%s\",\"endpoint\":\"%s:%d\","
		"\"player_id\":0,\"host\":true,\"grant\":\"%s\","
		"\"players\":%d,\"max_players\":%d,\"state\":\"staging\"}\n",
		(unsigned long long)m->id, m->code, g_advertise, m->udp_port,
		grant, m->players, m->max_players);
	logmsg("match %llu (code %s): created on udp %d",
		(unsigned long long)m->id, m->code, m->udp_port);
	return 201;
}

static int join_match(match_t *m, char *resp, size_t cap)
{
	if (m->players >= m->max_players)
		return 409;
	char grant[512];
	if (make_grant(m->id, 0, grant, sizeof(grant)) != 0)
		return 503;
	m->players++;
	size_t len = 0;
	appendf(resp, cap, &len,
		"{\"match_id\":%llu,\"code\":\"%s\",\"endpoint\":\"%s:%d\","
		"\"player_id\":0,\"host\":false,\"grant\":\"%s\","
		"\"players\":%d,\"max_players\":%d,\"state\":\"staging\"}\n",
		(unsigned long long)m->id, m->code, g_advertise, m->udp_port,
		grant, m->players, m->max_players);
	logmsg("match %llu (code %s): join grant issued (%d/%d)",
		(unsigned long long)m->id, m->code, m->players, m->max_players);
	return 200;
}

static int match_detail(match_t *m, char *resp, size_t cap)
{
	size_t len = 0;
	appendf(resp, cap, &len,
		"{\"match_id\":%llu,\"code\":\"%s\",\"endpoint\":\"%s:%d\","
		"\"players\":%d,\"max_players\":%d,\"state\":\"%s\"}\n",
		(unsigned long long)m->id, m->code, g_advertise, m->udp_port,
		m->players, m->max_players,
		m->state == 0 ? "staging" : "closed");
	return 200;
}

static int list_matches(char *resp, size_t cap)
{
	size_t len = 0;
	appendf(resp, cap, &len, "{\"matches\":[");
	int first = 1;
	for (int i = 0; i < MAX_MATCHES; i++) {
		if (!g_matches[i].used)
			continue;
		if (!first)
			appendf(resp, cap, &len, ",");
		first = 0;
		appendf(resp, cap, &len,
			"{\"match_id\":%llu,\"code\":\"%s\",\"endpoint\":\"%s:%d\","
			"\"players\":%d,\"max_players\":%d,\"state\":\"%s\"}",
			(unsigned long long)g_matches[i].id, g_matches[i].code,
			g_advertise, g_matches[i].udp_port,
			g_matches[i].players, g_matches[i].max_players,
			g_matches[i].state == 0 ? "staging" : "closed");
	}
	appendf(resp, cap, &len, "]}\n");
	return 200;
}

/* ------------------------------------------------------------------- http */

static void handle_client(int fd)
{
	char req[REQ_MAX + 1];
	size_t used = 0;
	struct pollfd pfd = { fd, POLLIN, 0 };
	while (used < REQ_MAX) {
		int pr = poll(&pfd, 1, 2000);
		if (pr <= 0)
			break;
		ssize_t n = recv(fd, req + used, REQ_MAX - used, 0);
		if (n <= 0)
			break;
		used += (size_t)n;
		req[used] = '\0';
		if (strstr(req, "\r\n\r\n") != NULL)
			break;
	}

	char method[16] = "";
	char path[PATH_MAX_ARG] = "";
	if (sscanf(req, "%15s %511s", method, path) != 2) {
		respond(fd, 400, "application/json", "{\"error\":\"bad request\"}\n");
		return;
	}
	char *q = strchr(path, '?');
	if (q)
		*q = '\0';
	logmsg("http %s %s", method, path);

	char resp[RESP_MAX];
	resp[0] = '\0';
	reap_children();

	if (strcmp(method, "GET") == 0 && strcmp(path, "/healthz") == 0) {
		respond(fd, 200, "text/plain", "ok\n");
		return;
	}
	if (strcmp(method, "GET") == 0 && strcmp(path, "/metrics") == 0) {
		snprintf(resp, sizeof(resp),
			"{\"matches\":%d,\"max_matches\":%d}\n", live_matches(), MAX_MATCHES);
		respond(fd, 200, "application/json", resp);
		return;
	}
	if (strcmp(path, "/v1/matches") == 0) {
		if (strcmp(method, "GET") == 0) {
			list_matches(resp, sizeof(resp));
			respond(fd, 200, "application/json", resp);
		} else if (strcmp(method, "POST") == 0) {
			int status = create_match(resp, sizeof(resp));
			respond(fd, status, "application/json",
				resp[0] ? resp : "{\"error\":\"no capacity\"}\n");
		} else {
			respond(fd, 405, "application/json", "{\"error\":\"method\"}\n");
		}
		return;
	}

	/* /v1/matches/<key>[/join|/leave] */
	const char *base = "/v1/matches/";
	if (strncmp(path, base, strlen(base)) == 0) {
		char key[64];
		char action[32] = "";
		const char *rest = path + strlen(base);
		const char *slash = strchr(rest, '/');
		size_t key_len = slash ? (size_t)(slash - rest) : strlen(rest);
		if (key_len == 0 || key_len >= sizeof(key)) {
			respond(fd, 404, "application/json", "{\"error\":\"match\"}\n");
			return;
		}
		memcpy(key, rest, key_len);
		key[key_len] = '\0';
		if (slash)
			snprintf(action, sizeof(action), "%s", slash + 1);

		match_t *m = find_by_code(key);
		if (m == NULL) {
			char *end = NULL;
			unsigned long long id = strtoull(key, &end, 10);
			if (end != key && *end == '\0')
				m = find_by_id(id);
		}
		if (m == NULL) {
			respond(fd, 404, "application/json", "{\"error\":\"match not found\"}\n");
			return;
		}

		if (action[0] == '\0' && strcmp(method, "GET") == 0) {
			match_detail(m, resp, sizeof(resp));
			respond(fd, 200, "application/json", resp);
		} else if (strcmp(action, "join") == 0 && strcmp(method, "POST") == 0) {
			int status = join_match(m, resp, sizeof(resp));
			respond(fd, status, "application/json", resp);
		} else if (strcmp(action, "leave") == 0 && strcmp(method, "POST") == 0) {
			if (m->players > 0)
				m->players--;
			snprintf(resp, sizeof(resp),
				"{\"match_id\":%llu,\"players\":%d}\n",
				(unsigned long long)m->id, m->players);
			respond(fd, 200, "application/json", resp);
		} else {
			respond(fd, 405, "application/json", "{\"error\":\"method\"}\n");
		}
		return;
	}

	respond(fd, 404, "application/json", "{\"error\":\"not found\"}\n");
}

static int run_server(void)
{
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		logmsg("socket: %s", strerror(errno));
		return 1;
	}
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)g_http_port);
	if (inet_pton(AF_INET, g_bind, &addr.sin_addr) != 1) {
		logmsg("bad --bind address: %s", g_bind);
		close(fd);
		return 1;
	}
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
		logmsg("bind %s:%d: %s", g_bind, g_http_port, strerror(errno));
		close(fd);
		return 1;
	}
	if (listen(fd, 64) != 0) {
		logmsg("listen: %s", strerror(errno));
		close(fd);
		return 1;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

	logmsg("lobbyd listening on http://%s:%d (udp %d-%d, advertise %s)",
		g_bind, g_http_port, UDP_PORT_MIN, UDP_PORT_MAX, g_advertise);
	if (g_no_spawn)
		logmsg("--no-spawn: matches are records only");
	else if (g_godot[0] == '\0')
		logmsg("WARNING: no --godot given; matches will have no server process");

	struct pollfd pfd = { fd, POLLIN, 0 };
	while (!g_stop) {
		int pr = poll(&pfd, 1, 500);
		if (pr > 0 && (pfd.revents & POLLIN)) {
			for (;;) {
				int client = accept(fd, NULL, NULL);
				if (client < 0) {
					if (errno == EAGAIN || errno == EWOULDBLOCK)
						break;
					if (errno == EINTR)
						continue;
					break;
				}
				handle_client(client);
				close(client);
			}
		}
		reap_children();
	}
	close(fd);
	stop_children();
	logmsg("lobbyd stopped");
	return 0;
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [options]\n"
		"  --bind ADDR            HTTP bind address (default 127.0.0.1)\n"
		"  --port N               HTTP port (default 18080)\n"
		"  --advertise-host HOST  Host returned to clients (default 127.0.0.1)\n"
		"  --secret S             HMAC secret; default: random per run\n"
		"  --godot PATH           engine/binary to spawn (WSL: /mnt/c/...)\n"
		"  --project PATH         Godot project path passed as --path\n"
		"  --log-dir DIR          match log directory (default /tmp)\n"
		"  --no-spawn             do not start match processes\n"
		"  --help\n",
		argv0);
}

static void gen_default_secret(void)
{
	random_hex(g_secret, 64);
}

int main(int argc, char **argv)
{
	srand((unsigned)time(NULL) ^ (unsigned)getpid());

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--bind") == 0 && i + 1 < argc) {
			snprintf(g_bind, sizeof(g_bind), "%s", argv[++i]);
		} else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
			g_http_port = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--advertise-host") == 0 && i + 1 < argc) {
			snprintf(g_advertise, sizeof(g_advertise), "%s", argv[++i]);
		} else if (strcmp(argv[i], "--secret") == 0 && i + 1 < argc) {
			snprintf(g_secret, sizeof(g_secret), "%s", argv[++i]);
		} else if (strcmp(argv[i], "--godot") == 0 && i + 1 < argc) {
			snprintf(g_godot, sizeof(g_godot), "%s", argv[++i]);
		} else if (strcmp(argv[i], "--project") == 0 && i + 1 < argc) {
			snprintf(g_project, sizeof(g_project), "%s", argv[++i]);
		} else if (strcmp(argv[i], "--log-dir") == 0 && i + 1 < argc) {
			snprintf(g_log_dir, sizeof(g_log_dir), "%s", argv[++i]);
		} else if (strcmp(argv[i], "--no-spawn") == 0) {
			g_no_spawn = 1;
		} else if (strcmp(argv[i], "--help") == 0) {
			usage(argv[0]);
			return 0;
		} else {
			fprintf(stderr, "unknown option: %s\n", argv[i]);
			usage(argv[0]);
			return 2;
		}
	}

	if (g_secret[0] == '\0') {
		const char *env = getenv("LOBBY_SECRET");
		if (env && *env)
			snprintf(g_secret, sizeof(g_secret), "%s", env);
	}
	if (g_secret[0] == '\0') {
		gen_default_secret();
		logmsg("WARNING: no --secret/LOBBY_SECRET; generated a per-run secret");
	}
	if (g_log_dir[0] != '\0') {
		mkdir(g_log_dir, 0755);
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);

	return run_server();
}
