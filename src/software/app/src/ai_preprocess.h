#ifndef AI_PREPROCESS_H
#define AI_PREPROCESS_H
#include <stdint.h>
#include "ai_result.h"
#include "ai_camera_geometry.h"

/* Enable only AFTER applying integrate_ai_pipeline.tcl and loading matching
 * ABI4/CAM2/LIV1/OVL3 hardware/XSA. An MMIO read to an absent AXI slave can hang the processor. */
#ifndef ENABLE_PL_PREPROCESS
#define ENABLE_PL_PREPROCESS 0
#endif
#ifndef ENABLE_CAMERA_MODELS
#define ENABLE_CAMERA_MODELS 0
#endif
#define AI_PREPROCESS_BASE 0x43C10000u
#define AI_CAMERA_FEATURE 0x43414D32u
#define AI_OVERLAY_ABI_SIGNATURE UINT32_C(0x4F564C33)
#define AI_OVERLAY_BUILD_ID UINT32_C(0x26110104)
/* Eight result slots, three models; metadata/status/matched flags in bits 2:0. */
#define AI_OVERLAY_ABI_CAPS UINT32_C(0x00080307)

typedef struct {
    uint32_t address, bytes, frame_id, generation, raw_address;
    uint64_t captured_cycles; /* AXI tap SOF, 100 MHz; not a sensor exposure time */
    /* Raw-only frontend: address==raw_address and bytes==AI_RAW_BYTES (RGB565).
     * Both fields describe the acquired lease even if CONTROL changes later. */
} ai_tensor_lease;
typedef struct {
    uint32_t snapshots, dropped_sofs, fault;
    uint32_t last_snapshot_error, rejected_releases;
    uint32_t inferences, rejected_results, display_results;
    uint32_t displayed_frames, display_fault;
    uint32_t processed_active, unique_frames, repeated_frames;
    uint32_t overlay_valid, result_age_ms, publication_age_ms, result_frame;
    uint32_t box_count, max_score_pct, matched_view;
} ai_preprocess_stats;

int ai_preprocess_init(void); /* 1 enabled, 0 compiled out, -1 ABI/feature mismatch */
/* CAM2/LIV1 packed-RGB565 extension. Init enables independent live mode;
 * global capture_run starts preview while the PS inference flag stays off.
 * For switching: set_capture(0), drain readers, release/publish own lease,
 * discard_pending(), camera_mode(1), select/configure model, set_capture(1).
 * Model switches clear overlay and retain live display references.
 * Display-owned slots retire only after their complete frame/AXI fence. */
int ai_preprocess_raw_supported(void);
uint32_t ai_preprocess_drain_status(void); /* bits 0 snapshot, 2 PS lease,
    5 raw queued, 7 display flush pending; retired bits 1/3/4/6 read zero;
    UINT32_MAX unavailable */
int ai_preprocess_set_capture(int enabled);
int ai_preprocess_set_processed(int enabled);
int ai_preprocess_set_matched(int enabled);
int ai_preprocess_set_overlay_state(uint32_t model_id,enum ai_overlay_status status);
/* Poll with capture and processed display off: one request discards queued
 * work and drains old display descriptors. 1 complete, 0 pending/busy,
 * -1 unsupported. A scanout fault never acknowledges or frees held DDR. */
int ai_preprocess_discard_pending(void);
int ai_preprocess_camera_mode(int raw_mode); /* raw_mode must be 1 */
int ai_preprocess_claim(ai_tensor_lease *lease); /* 1 claimed, 0 none, -1 busy/invalid */
int ai_preprocess_release(const ai_tensor_lease *lease); /* Only after ALL readers drain. */
/* Manual/software result path, including PS-managed model-independent camera
 * inference. Call only after the model has produced its matching real result. */
int ai_preprocess_publish(const ai_tensor_lease *lease,const ai_frame_result *result);
void ai_preprocess_get_stats(ai_preprocess_stats *stats);
#endif
