/* Compact SHA-256 + HMAC-SHA256.  FIPS 180-4 / RFC 2104. */

#include "sha256.h"

#include <stdlib.h>
#include <string.h>

static const uint32_t K[64] = {
	0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
	0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
	0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
	0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
	0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
	0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
	0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
	0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
	0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
	0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
	0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
	0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
	0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
	0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
	0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
	0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t state[8], const uint8_t block[64])
{
	uint32_t w[64];
	for (int i = 0; i < 16; i++) {
		w[i] = ((uint32_t)block[i * 4] << 24) |
		       ((uint32_t)block[i * 4 + 1] << 16) |
		       ((uint32_t)block[i * 4 + 2] << 8) |
		       (uint32_t)block[i * 4 + 3];
	}
	for (int i = 16; i < 64; i++) {
		uint32_t s0 = ROTR(w[i - 15], 7) ^ ROTR(w[i - 15], 18) ^ (w[i - 15] >> 3);
		uint32_t s1 = ROTR(w[i - 2], 17) ^ ROTR(w[i - 2], 19) ^ (w[i - 2] >> 10);
		w[i] = w[i - 16] + s0 + w[i - 7] + s1;
	}

	uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
	uint32_t e = state[4], f = state[5], g = state[6], h = state[7];

	for (int i = 0; i < 64; i++) {
		uint32_t s1 = ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25);
		uint32_t ch = (e & f) ^ (~e & g);
		uint32_t t1 = h + s1 + ch + K[i] + w[i];
		uint32_t s0 = ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22);
		uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
		uint32_t t2 = s0 + maj;
		h = g;
		g = f;
		f = e;
		e = d + t1;
		d = c;
		c = b;
		b = a;
		a = t1 + t2;
	}

	state[0] += a;
	state[1] += b;
	state[2] += c;
	state[3] += d;
	state[4] += e;
	state[5] += f;
	state[6] += g;
	state[7] += h;
}

void sha256(const uint8_t *data, size_t len, uint8_t out[32])
{
	uint32_t state[8] = {
		0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
		0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
	};
	uint64_t bit_len = (uint64_t)len * 8u;
	size_t full = len / 64;
	for (size_t i = 0; i < full; i++) {
		sha256_block(state, data + i * 64);
	}

	uint8_t tail[128];
	size_t rem = len - full * 64;
	memcpy(tail, data + full * 64, rem);
	tail[rem] = 0x80;
	size_t tail_len = (rem < 56) ? 64 : 128;
	memset(tail + rem + 1, 0, tail_len - rem - 1);
	for (int i = 0; i < 8; i++) {
		tail[tail_len - 1 - i] = (uint8_t)(bit_len >> (i * 8));
	}
	for (size_t off = 0; off < tail_len; off += 64) {
		sha256_block(state, tail + off);
	}

	for (int i = 0; i < 8; i++) {
		out[i * 4] = (uint8_t)(state[i] >> 24);
		out[i * 4 + 1] = (uint8_t)(state[i] >> 16);
		out[i * 4 + 2] = (uint8_t)(state[i] >> 8);
		out[i * 4 + 3] = (uint8_t)state[i];
	}
}

void hmac_sha256(const uint8_t *key, size_t key_len,
                 const uint8_t *data, size_t data_len, uint8_t out[32])
{
	uint8_t k[64];
	memset(k, 0, sizeof(k));
	if (key_len > 64) {
		sha256(key, key_len, k);
	} else {
		memcpy(k, key, key_len);
	}

	uint8_t ipad[64];
	uint8_t opad[64];
	for (int i = 0; i < 64; i++) {
		ipad[i] = (uint8_t)(k[i] ^ 0x36);
		opad[i] = (uint8_t)(k[i] ^ 0x5c);
	}

	uint8_t inner[32];
	uint8_t *buf = (uint8_t *)malloc(sizeof(ipad) + data_len);
	if (buf == NULL) {
		memset(out, 0, 32);
		return;
	}
	memcpy(buf, ipad, 64);
	memcpy(buf + 64, data, data_len);
	sha256(buf, 64 + data_len, inner);
	free(buf);

	uint8_t outer_input[64 + 32];
	memcpy(outer_input, opad, 64);
	memcpy(outer_input + 64, inner, 32);
	sha256(outer_input, sizeof(outer_input), out);
}
