#ifndef MS3D_SHA256_H
#define MS3D_SHA256_H

#include <stddef.h>
#include <stdint.h>

/* Plain SHA-256 and HMAC-SHA256, so lobbyd has no OpenSSL dependency. */

void sha256(const uint8_t *data, size_t len, uint8_t out[32]);
void hmac_sha256(const uint8_t *key, size_t key_len,
                 const uint8_t *data, size_t data_len, uint8_t out[32]);

#endif
