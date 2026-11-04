/* SPDX-License-Identifier: MIT */
/* Driver metadata only: no mmap, register ioctl, key access or DDR access. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "unified_npu_uapi.h"

struct expected_region {
    const char *name;
    uint32_t phys, size, flags;
};
static const struct expected_region expected[NPU_REGIONS] = {
    {"FRONTEND",  0x43c10000u, 0x00008000u, 0},
    {"GRAPH",     0x43c18000u, 0x00008000u, 0},
    {"RAW",       0x12000000u, 0x02000000u, NPU_MAP_DDR},
    {"MODELS",    0x14000000u, 0x06000000u, NPU_MAP_DDR},
    {"WORKSPACE", 0x1a000000u, 0x01000000u, NPU_MAP_DDR},
    {"COCO",      0x1b000000u, 0x01000000u, NPU_MAP_DDR},
    {"CONTROL",   0x41200000u, 0x00010000u, 0},
    {"STATS",     0x41210000u, 0x00010000u, 0}
};
_Static_assert(NPU_RUNTIME_ABI == 3, "Expected ABI 3");
_Static_assert(NPU_REGIONS == 8, "Expected eight regions");
_Static_assert(sizeof(struct npu_ioc) == 32, "Unexpected ioctl structure size");

int main(void)
{
    unsigned int region;
    int failed = 0;
    int fd = open("/dev/unified-npu", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "ERROR: open /dev/unified-npu: %s\n", strerror(errno));
        return 1;
    }
    for (region = 0; region < NPU_REGIONS; ++region) {
        struct npu_ioc info = {0};
        info.abi = NPU_RUNTIME_ABI;
        info.region = region;
        if (ioctl(fd, NPU_IOC_INFO, &info) < 0) {
            fprintf(stderr, "ERROR: INFO region %u: %s\n", region, strerror(errno));
            failed = 1;
            break;
        }
        if (info.abi != NPU_RUNTIME_ABI || info.region != region ||
            info.phys != expected[region].phys ||
            info.size != expected[region].size ||
            info.flags != expected[region].flags ||
            info.offset || info.value || info.reserved) {
            fprintf(stderr,
                    "ERROR: INFO mismatch for region %u: abi=%" PRIu32
                    " region=%" PRIu32 " phys=%08" PRIx32
                    " size=%08" PRIx32 " flags=%08" PRIx32 "\n",
                    region, info.abi, info.region, info.phys, info.size, info.flags);
            failed = 1;
            break;
        }
        printf("INFO_OK: region=%u %s phys=0x%08" PRIx32
               " size=0x%08" PRIx32 " flags=0x%08" PRIx32 "\n",
               region, expected[region].name, info.phys, info.size, info.flags);
    }
    if (close(fd) < 0) {
        fprintf(stderr, "ERROR: close /dev/unified-npu: %s\n", strerror(errno));
        failed = 1;
    }
    if (failed) return 1;
    puts("DRIVER_INFO_PASS: ABI 3 and all eight driver windows match.");
    puts("No PL registers or DDR were accessed; PL identity and inference remain unverified.");
    return 0;
}
