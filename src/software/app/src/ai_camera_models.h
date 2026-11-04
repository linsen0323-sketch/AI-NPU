#ifndef AI_CAMERA_MODELS_H
#define AI_CAMERA_MODELS_H
#include <stdint.h>
#include "ai_preprocess.h"
#include "ai_display.h"

#ifndef ENABLE_CAMERA_MODELS
#define ENABLE_CAMERA_MODELS 0
#endif

#define AI_CAMERA_MAILBOX_BASE UINT32_C(0x00F00100)
#define AI_CAMERA_MAILBOX_MAGIC UINT32_C(0x43414D33)
enum ai_camera_state {
    AI_CAMERA_STOPPED=0, AI_CAMERA_QUIESCE=1, AI_CAMERA_VERIFY=2,
    AI_CAMERA_INVALIDATE=3, AI_CAMERA_CONFIGURE=4, AI_CAMERA_CAPTURE=5,
    AI_CAMERA_PREPARE=6, AI_CAMERA_START=7, AI_CAMERA_RUNNING=8,
    AI_CAMERA_POSTPROCESS=9, AI_CAMERA_PUBLISH=10, AI_CAMERA_ERROR=11
};
enum ai_camera_fault {
    AI_CAMERA_OK=0, AI_CAMERA_BAD_ABI=1, AI_CAMERA_BAD_REQUEST=2,
    AI_CAMERA_FOREIGN_OWNER=3, AI_CAMERA_BAD_CRC=4,
    AI_CAMERA_BAD_CONFIGURATION=5, AI_CAMERA_BAD_LEASE=6,
    AI_CAMERA_MATH_ERROR=7, AI_CAMERA_BAD_RESULT=8,
    AI_CAMERA_TIMEOUT=9, AI_CAMERA_RELEASE_ERROR=10,
    AI_CAMERA_GRAPH_FAULT=0x10000, AI_CAMERA_FRONTEND_FAULT=0x20000
};
/* Debugger: write request_model FIRST, then increment request_seq LAST.
 * 0=stop AI and keep live preview; 1=ResNet18; 3=NEU6; 4=COCO80;
 * 2 is unsupported.
 * ack_seq acknowledges the completed switch, not merely receipt of the command.
 * Read all fields as a diagnostic snapshot; active_model alone is not a lock.
 */
typedef struct {
    uint32_t magic, abi, request_model, request_seq;
    uint32_t ack_seq, active_model, state, fault;
    uint32_t completed, frame_id, generation, graph_op;
    /* Raw PL cycles, zero/unavailable when graph DIA bit2 is clear.
     * graph_ms then uses monotonic PS submission-to-DONE time, including polls.
     * Struct layout and the existing mailbox ABI remain unchanged. */
    uint32_t cycles_low, cycles_high, switch_pending, verified_model_mask;
    uint32_t prepare_ms, graph_ms, postprocess_ms, total_ms;
    /* Last discarded terminal descriptor, including cancelled graph detail.
     * Diagnostic only: discarded output is never published. */
    uint32_t discarded_graph_fault;
} ai_camera_mailbox;

typedef struct {
    ai_frame_result result;
    uint32_t model_id, classes, frame_id, generation;
} ai_camera_detection_snapshot;
/* Cooperative event-loop access. Invalidated on every requested switch. */
int ai_camera_models_detection(ai_camera_detection_snapshot *out);
/* Confidence is display-only for both detectors after original NMS.
 * COCO's configurable NMS is retained; NEU's frozen 0.65 NMS is unchanged. */
int ai_camera_models_set_thresholds(float confidence, float nms);
int ai_camera_models_set_display(const ai_display_options *options);
int ai_camera_models_select_display(uint32_t model_id);

int ai_camera_models_init(void);
/* Only after a cold-boot loader has verified immutable resident images.
 * Accepted exclusively in STOPPED with no leases/tasks; no bypass during run. */
int ai_camera_models_set_resident_images(uint32_t verified_mask);
void ai_camera_models_request(uint32_t model_id);
/* Call frequently from the video event loop. Time is monotonic milliseconds.
 * Each call performs bounded CRC work, up to 16 preprocessing steps or a bounded
 * portion of NMS. Never blocks waiting for the accelerator or frame capture.
 */
void ai_camera_models_poll(uint64_t now_ms);
const volatile ai_camera_mailbox *ai_camera_models_status(void);
const char *ai_camera_models_name(uint32_t model_id);
#endif
