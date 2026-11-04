/* SPDX-License-Identifier: MIT */
#ifndef NPU_SD_LOADER_H
#define NPU_SD_LOADER_H
#include <stdint.h>
enum npu_sd_error {
    NPU_SD_OK=0, NPU_SD_FILESYSTEM=-1, NPU_SD_MANIFEST=-2, NPU_SD_IMAGE=-3,
    NPU_SD_ABI=-4, NPU_SD_FOREIGN_OWNER=-5, NPU_SD_DRAIN_TIMEOUT=-6,
    NPU_SD_CACHE_STATE=-7, NPU_SD_DDR_VERIFY=-8
};
/* FatFs drive must already be mounted. Call synchronously during cold startup
 * in camera STOPPED/model0, before issuing any model request. Both A9 cores
 * must not run competing runtime/DMA code. Cache-off is checked, not changed.
 * Example root: "0:/npu" (8.3 compatible). Copies 3 immutable images only; does not
 * change workspace/inputs, start a task, release foreign leases or reset PL.
 * Production bit1 hardware requires NPUPRE1/AFF1 plans. Legacy bit1=0 hardware
 * accepts only bit1=0 images: subset feature matching alone is insufficient.
 * File preflight validates the
 * complete package, tensor/TLV/instruction/index/record structure and affine
 * bounds before the first DDR write; after draining, hashes are checked again
 * while copying and by DDR readback. `resident_mask` is assigned 7 only on full
 * success; 0 on every failure. PS parsing is a load-time cost, not per-frame.
 */
int npu_sd_preload(const char *bundle_root, uint32_t *resident_mask);
/* Optional separately hashed COCO80 image at <root>/coco80/model.bin.
 * Same cold-start ownership/cache requirements; bit 3 only on full success.
 * Does not modify either original image or the original manifest format. */
int npu_sd_preload_coco80(const char *bundle_root, uint32_t *resident_mask);
#endif
