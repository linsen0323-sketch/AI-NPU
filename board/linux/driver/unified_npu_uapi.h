/* SPDX-License-Identifier: MIT */
#ifndef UNIFIED_NPU_UAPI_H
#define UNIFIED_NPU_UAPI_H
#include <linux/types.h>
#include <linux/ioctl.h>
#define NPU_RUNTIME_ABI 3
/* mmap offset = selector * PAGE_SIZE; mappings must have the exact size. */
enum npu_region { NPU_FRONTEND, NPU_GRAPH, NPU_RAW, NPU_MODELS,
                  NPU_WORKSPACE, NPU_COCO, NPU_CONTROL, NPU_STATS, NPU_REGIONS };
struct npu_ioc {
    __u32 abi, region, offset, value, phys, size, flags, reserved;
};
#define NPU_IOC_INFO  _IOWR('N', 1, struct npu_ioc)
#define NPU_IOC_READ  _IOWR('N', 2, struct npu_ioc)
#define NPU_IOC_WRITE _IOWR('N', 3, struct npu_ioc)
#define NPU_IOC_FENCE _IOWR('N', 4, struct npu_ioc)
#define NPU_IOC_KEYS  _IOWR('N', 5, struct npu_ioc)
#define NPU_MAP_DDR 1
#endif
