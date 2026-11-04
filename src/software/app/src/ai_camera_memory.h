#ifndef AI_CAMERA_MEMORY_H
#define AI_CAMERA_MEMORY_H
#include <stdint.h>

/* CPU-private image/stack/scratch: 0x00100000..0x00EFFFFF, write-back.
 * Diagnostics: 0x00F00000..0x00FFFFFF, non-cacheable.
 * Video, camera leases, all model slots and workspace: 0x10000000..0x1FFFFFFF,
 * inner AND outer non-cacheable normal memory. HP2/HP3 are noncoherent.
 * Never cache a second alias of these buffers. Driver ownership barriers
 * still order CPU->PL handoff and PL->CPU reads. */
void ai_camera_memory_init(void);
extern uint32_t ai_camera_memory_split_ready;
static inline int ai_camera_memory_uncached(void) {
#if defined(AI_CAMERA_MODELS_TEST)
    return 1;
#elif defined(__arm__)
    uint32_t sctlr;
    __asm__ volatile ("mrc p15, 0, %0, c1, c0, 0" : "=r" (sctlr));
    /* Accept the previous all-caches-off contract as a recovery fallback. */
    if (!(sctlr&4u) && !(*(volatile uint32_t *)(uintptr_t)0xF8F02100u&1u)) return 1;
    return (sctlr&1u) && ai_camera_memory_split_ready;
#else
    return 0;
#endif
}
#endif
