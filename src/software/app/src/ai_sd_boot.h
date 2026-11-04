#ifndef AI_SD_BOOT_H
#define AI_SD_BOOT_H
#include <stdint.h>
/* Cold-start only: caller has stopped the camera/model manager. */
int ai_sd_boot_load(uint32_t *resident_mask);
#endif
