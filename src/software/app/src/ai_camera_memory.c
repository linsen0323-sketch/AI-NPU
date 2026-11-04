#include "ai_camera_memory.h"
#include "xil_cache.h"
#include "xil_mmu.h"

uint32_t ai_camera_memory_split_ready;

void ai_camera_memory_init(void) {
    /* Runs before capture/graph leases. BSP disable cleans both levels before
     * attributes change. MMIO keeps its BSP mapping. */
    Xil_DCacheDisable();
    ai_camera_memory_split_ready = 0;
    for (uint32_t mb = 1; mb < 15; ++mb)
        Xil_SetTlbAttributes((INTPTR)(mb << 20), NORM_WB_CACHE);
    Xil_SetTlbAttributes((INTPTR)0x00F00000u, NORM_NONCACHE);
    for (uint32_t mb = 0x100; mb < 0x200; ++mb)
        Xil_SetTlbAttributes((INTPTR)(mb << 20), NORM_NONCACHE);
#if defined(__arm__)
    uint32_t ttbr, ttbcr, sctlr;
    __asm__ volatile ("dsb sy\n\tisb" ::: "memory");
    __asm__ volatile ("mrc p15, 0, %0, c2, c0, 0" : "=r"(ttbr));
    __asm__ volatile ("mrc p15, 0, %0, c2, c0, 2" : "=r"(ttbcr));
    __asm__ volatile ("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));
    /* Standalone BSP: flat 4096-entry short-descriptor table. Fall back to
     * former uncached operation if a foreign MMU configuration is present. */
    if ((ttbcr & 0x80000007u) || !(sctlr & 1u) || (sctlr & (1u << 28))) return;
    const volatile uint32_t *table = (const volatile uint32_t *)(uintptr_t)(ttbr & 0xFFFFC000u);
    const uint32_t attribute_mask = 0x0001700Fu;
    if ((table[15] & attribute_mask) != (NORM_NONCACHE & attribute_mask) ||
        (table[15] & 0xFFF00000u) != 0x00F00000u) return;
    for (uint32_t mb = 0x100; mb < 0x200; ++mb)
        if ((table[mb] & attribute_mask) != (NORM_NONCACHE & attribute_mask) ||
            (table[mb] & 0xFFF00000u) != (mb << 20)) return;
    ai_camera_memory_split_ready = 1;
    Xil_DCacheEnable();
    __asm__ volatile ("dsb sy\n\tisb" ::: "memory");
#endif
}
