#include "ai_preprocess.h"
#include "ai_camera_memory.h"
#include <stddef.h>

#if ENABLE_PL_PREPROCESS
#include "xil_cache.h"
static int active;
static int discard_waiting;
static inline void barrier(void) { __asm__ volatile ("dmb sy" ::: "memory"); }
static uint32_t reg_read(uint32_t offset) {
    return *(volatile uint32_t *)(uintptr_t)(AI_PREPROCESS_BASE+offset);
}
static void reg_write(uint32_t offset,uint32_t value) {
    *(volatile uint32_t *)(uintptr_t)(AI_PREPROCESS_BASE+offset)=value;
    barrier();
}
int ai_preprocess_init(void) {
    active=0;
    if (reg_read(0x00u)!=0x50525031u || reg_read(0x5Cu)!=8u || reg_read(0x94u)!=0x4C495631u ||
        reg_read(0xACu)!=AI_OVERLAY_ABI_SIGNATURE || reg_read(0x1A4u)!=AI_OVERLAY_BUILD_ID ||
        reg_read(0x1A8u)!=AI_OVERLAY_ABI_CAPS) return -1;
    if (ENABLE_CAMERA_MODELS && reg_read(0x88u)!=AI_CAMERA_FEATURE) return -1;
    if (ENABLE_CAMERA_MODELS && !ai_camera_memory_uncached()) return -1;
    discard_waiting=0;
    reg_write(0x04u,56u); /* Live preview plus matched-result geometry. */
    reg_write(0x194u,0u);reg_write(0x198u,0u);reg_write(0x19Cu,0u);
    reg_write(0x1A0u,AI_OVERLAY_IDLE);
    active=1; return 1;
}
int ai_preprocess_raw_supported(void) {
    return active && reg_read(0x88u)==AI_CAMERA_FEATURE;
}
uint32_t ai_preprocess_drain_status(void) {
    return ai_preprocess_raw_supported() ? reg_read(0x8Cu) : UINT32_MAX;
}
static void update_control(uint32_t mask,uint32_t value) {
    uint32_t control=reg_read(0x04u);
    control=(control&~mask)|(value&mask);
    reg_write(0x04u,control);
}
int ai_preprocess_set_capture(int enabled) {
    if (!active) return -1;
    update_control(1u,enabled ? 1u : 0u); return 1;
}
int ai_preprocess_set_processed(int enabled) {
    if (!active) return -1;
    update_control(4u,enabled ? 4u : 0u); return 1;
}
int ai_preprocess_set_matched(int enabled) {
    if (!active) return -1;
    update_control(32u,enabled ? 32u : 0u); return 1;
}
int ai_preprocess_set_overlay_state(uint32_t model_id,enum ai_overlay_status status) {
    if(!active || (uint32_t)status>AI_OVERLAY_ERROR ||
       (model_id!=0u && model_id!=1u && model_id!=3u && model_id!=4u))return -1;
    reg_write(0x194u,model_id);
    if(status!=AI_OVERLAY_RUN){reg_write(0x198u,0u);reg_write(0x19Cu,0u);}
    reg_write(0x1A0u,(uint32_t)status);
    return 1;
}
int ai_preprocess_discard_pending(void) {
    if (!ai_preprocess_raw_supported()) return -1;
    uint32_t control=reg_read(0x04u);
    uint32_t status=reg_read(0x8Cu);
    // Camera/display storage is disjoint from model workspaces. A switch
    // only needs the caller's PS lease retired; live DMA can continue safely.
    if (control&16u) {
        if (status&4u) return 0;
        reg_write(0x90u,16u); // Clear stale overlay, retain live video references.
        discard_waiting=0; return 1;
    }
    if (control&5u) return 0;
    if (discard_waiting) {
        if (status&128u) return 0;
        discard_waiting=0; return 1;
    }
    if (status&135u) return 0;
    /* A single request purges unclaimed work and drains every old display
     * descriptor. Repeated polls observe the same handshake instead of
     * continuously issuing another flush after acknowledgement. */
    reg_write(0x90u,3u); discard_waiting=1; return 0;
}
int ai_preprocess_camera_mode(int raw_mode) {
    if (!raw_mode || !ai_preprocess_raw_supported()) return -1;
    if (reg_read(0x04u)&16u) return (reg_read(0x8Cu)&4u) ? 0 : 1;
    if ((reg_read(0x04u)&1u) || (reg_read(0x8Cu)&135u)) return 0;
    /* Only packed RGB565 leases remain; discard unclaimed raw frames. */
    reg_write(0x90u,1u);
    update_control(10u,8u); return 1;
}
int ai_preprocess_claim(ai_tensor_lease *lease) {
    if (!active || !lease || (reg_read(0x04u)&2u) || reg_read(0x40u)) return -1;
    reg_write(0x08u,1u);
    if (!reg_read(0x40u)) return 0;
    lease->address=reg_read(0x44u); lease->bytes=reg_read(0x58u);
    lease->frame_id=reg_read(0x48u); lease->generation=reg_read(0x4Cu);
    lease->raw_address=reg_read(0x60u);
    lease->captured_cycles=(uint64_t)reg_read(0x50u) | ((uint64_t)reg_read(0x54u)<<32);
    barrier();
    // Camera-model mode requires shared video/model regions uncached;
    // CPU-private tables/scratch may remain cached without per-frame maintenance.
    // A non-camera client still needs cache maintenance for its raw lease.
    if (!ENABLE_CAMERA_MODELS || lease->address!=lease->raw_address || lease->bytes!=AI_RAW_BYTES)
        Xil_DCacheInvalidateRange((INTPTR)lease->address,lease->bytes);
    barrier(); return 1;
}
int ai_preprocess_release(const ai_tensor_lease *lease) {
    if (!active || !lease || !reg_read(0x40u) || (reg_read(0x100u)&2u) ||
        reg_read(0x48u)!=lease->frame_id || reg_read(0x4Cu)!=lease->generation) return -1;
    barrier();
    reg_write(0x10u,lease->frame_id); reg_write(0x14u,lease->generation);
    reg_write(0x0Cu,1u);
    return reg_read(0x40u) ? -1 : 1;
}
static int valid_bcd(uint32_t value,uint32_t digits) {
    for(uint32_t k=0;k<digits;++k){if((value&15u)>9u)return 0;value>>=4;}
    return value==0u;
}
int ai_preprocess_publish(const ai_tensor_lease *lease,const ai_frame_result *result) {
    if (!active || !lease || !result || result->box_count>8u || (reg_read(0x04u)&2u) ||
        !reg_read(0x40u) || reg_read(0x48u)!=lease->frame_id || reg_read(0x4Cu)!=lease->generation ||
        reg_read(0x1A0u)!=AI_OVERLAY_RUN ||
        (result->model_id!=1u && result->model_id!=3u && result->model_id!=4u) ||
        result->class_id>7u || result->detection_mode>1u ||
        (!result->detection_mode && result->box_count) ||
        (result->score_pct>100u && (result->detection_mode || result->score_pct!=127u)) ||
        !valid_bcd(result->inference_ms_bcd,5u) || !valid_bcd(result->result_fps_bcd,4u)) return -1;
    /* Validate the entire descriptor before touching staging registers. */
    for(uint32_t i=0;i<result->box_count;++i) {
        const ai_detection_box *box=&result->boxes[i];
        if(box->xmin>=box->xmax || box->ymin>=box->ymax ||
           box->xmax>AI_RAW_WIDTH || box->ymax>AI_RAW_HEIGHT ||
           box->class_id>7u || box->score_pct>100u)return -1;
    }
    reg_write(0x180u,lease->frame_id); reg_write(0x184u,lease->generation);
    reg_write(0x188u,(result->class_id&7u)|((uint32_t)(result->score_pct&127u)<<8));
    reg_write(0x18Cu,(result->box_count&15u)|(result->detection_mode ? 16u : 0u));
    uint32_t hi,lo,check;
    do { hi=reg_read(0xB4u); lo=reg_read(0xB0u); check=reg_read(0xB4u); } while (hi!=check);
    uint64_t elapsed=(((uint64_t)hi<<32)|lo)-lease->captured_cycles;
    uint32_t delay_ms=(uint32_t)(elapsed/100000u),bcd=0;
    if (delay_ms>99999u) delay_ms=99999u;
    for (uint32_t digit=0;digit<5u;++digit) { bcd|=(delay_ms%10u)<<(digit*4u); delay_ms/=10u; }
    reg_write(0x190u,bcd);
    reg_write(0x194u,result->model_id);
    reg_write(0x198u,result->inference_ms_bcd);
    reg_write(0x19Cu,result->result_fps_bcd);
    for (uint32_t i=0;i<result->box_count;++i) {
        const ai_detection_box *box=&result->boxes[i];
        reg_write(0x200u+i*16u,(uint32_t)box->xmin|((uint32_t)box->ymin<<16));
        reg_write(0x204u+i*16u,(uint32_t)box->xmax|((uint32_t)box->ymax<<16));
        reg_write(0x208u+i*16u,(box->class_id&7u)|((uint32_t)(box->score_pct&127u)<<8));
    }
    barrier(); reg_write(0x120u,1u);
    return reg_read(0x40u) ? -1 : 1;
}
void ai_preprocess_get_stats(ai_preprocess_stats *stats) {
    if (!stats) return;
    *stats=(ai_preprocess_stats){0};
    if (!active) return;
    stats->snapshots=reg_read(0x20u); stats->dropped_sofs=reg_read(0x24u);
    stats->fault=reg_read(0x1Cu); stats->last_snapshot_error=reg_read(0x30u);
    stats->rejected_releases=reg_read(0x38u);
    stats->inferences=reg_read(0x64u);
    stats->rejected_results=reg_read(0x6Cu); stats->display_results=reg_read(0x70u);
    stats->displayed_frames=reg_read(0x80u);
    stats->display_fault=reg_read(0x84u);
    stats->processed_active=(reg_read(0x18u)>>6)&1u;
    stats->unique_frames=reg_read(0x98u); stats->repeated_frames=reg_read(0x9Cu);
    stats->overlay_valid=reg_read(0xA4u)&1u;
    stats->result_age_ms=reg_read(0xA0u)/100000u;
    stats->publication_age_ms=reg_read(0xB8u)/100000u;
    stats->result_frame=reg_read(0xBCu); stats->box_count=reg_read(0xC4u)&15u;
    stats->max_score_pct=reg_read(0xC8u)&127u; stats->matched_view=(reg_read(0x04u)>>5)&1u;
}
#else
int ai_preprocess_init(void) { return 0; }
int ai_preprocess_raw_supported(void) { return 0; }
uint32_t ai_preprocess_drain_status(void) { return UINT32_MAX; }
int ai_preprocess_set_capture(int enabled) { (void)enabled; return -1; }
int ai_preprocess_set_processed(int enabled) { (void)enabled; return -1; }
int ai_preprocess_set_matched(int enabled) { (void)enabled; return -1; }
int ai_preprocess_set_overlay_state(uint32_t m,enum ai_overlay_status s) { (void)m;(void)s;return -1; }
int ai_preprocess_discard_pending(void) { return -1; }
int ai_preprocess_camera_mode(int raw_mode) { (void)raw_mode; return -1; }
int ai_preprocess_claim(ai_tensor_lease *lease) { (void)lease; return 0; }
int ai_preprocess_release(const ai_tensor_lease *lease) { (void)lease; return 0; }
int ai_preprocess_publish(const ai_tensor_lease *lease,const ai_frame_result *result) {
    (void)lease; (void)result; return 0;
}
void ai_preprocess_get_stats(ai_preprocess_stats *stats) {
    if (stats) *stats=(ai_preprocess_stats){0};
}
#endif
