#include "ai_board_keys.h"
#include "ai_preprocess.h"

static uint32_t previous,stable,active;
static uint64_t changed[4];
static uint32_t raw_keys(void) {
    uint32_t ps=*(volatile uint32_t *)(uintptr_t)0xE000A060u;
    uint32_t pl=*(volatile uint32_t *)(uintptr_t)(AI_PREPROCESS_BASE+0x344u);
    uint32_t keys=0;
    if (!(ps&(1u<<12))) keys|=AI_BOARD_KEY_RESNET;
    if (!(ps&(1u<<11))) keys|=AI_BOARD_KEY_NEU;
    if (!(pl&1u)) keys|=AI_BOARD_KEY_COCO;
    if (!(pl&2u)) keys|=AI_BOARD_KEY_RUN;
    return keys;
}
int ai_board_keys_init(uint64_t now_ms) {
    active=0;
    if (*(volatile uint32_t *)(uintptr_t)(AI_PREPROCESS_BASE+0x340u)!=0x4B455931u)
        return -1;
    /* Matching PS7 initialization supplies the MIO pinmux. Set GPIO input
     * direction only; never reconfigure SLCR or drive these pulled-up pins. */
    volatile uint32_t *direction=(volatile uint32_t *)(uintptr_t)0xE000A204u;
    *direction&=~((1u<<11)|(1u<<12));
    __asm__ volatile("dsb sy":::"memory");
    previous=stable=raw_keys();
    for (uint32_t k=0;k<4u;++k) changed[k]=now_ms;
    active=1;return 1;
}
uint32_t ai_board_keys_poll(uint64_t now_ms) {
    if (!active) return 0;
    uint32_t raw=raw_keys(),pressed=0;
    for (uint32_t k=0;k<4u;++k) {
        uint32_t bit=1u<<k;
        if ((raw^previous)&bit) changed[k]=now_ms;
        if (((raw^stable)&bit) && now_ms-changed[k]>=25u) {
            stable=(stable&~bit)|(raw&bit);
            pressed|=raw&bit;
        }
    }
    previous=raw;return pressed;
}
