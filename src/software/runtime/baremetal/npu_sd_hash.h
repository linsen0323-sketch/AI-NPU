/* SPDX-License-Identifier: MIT */
#ifndef NPU_SD_HASH_H
#define NPU_SD_HASH_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    uint32_t state[8];
    uint64_t bytes;
    uint8_t block[64];
    size_t used;
} npu_sha256;
void npu_sha256_init(npu_sha256 *ctx);
void npu_sha256_update(npu_sha256 *ctx, const void *data, size_t bytes);
void npu_sha256_final(npu_sha256 *ctx, uint8_t out[32]);
uint32_t npu_crc32_update(uint32_t state, const void *data, size_t bytes);
#endif
