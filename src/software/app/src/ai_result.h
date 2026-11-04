#ifndef AI_RESULT_H
#define AI_RESULT_H
#include <stdint.h>
typedef struct {
    uint16_t xmin, ymin, xmax, ymax; /* Original frame; maxima exclusive. */
    uint8_t class_id, score_pct;
} ai_detection_box;
typedef struct {
    uint8_t class_id, score_pct, detection_mode, box_count;
    ai_detection_box boxes[8];
    /* OVL3: logical model1/3/4, five decimal inference milliseconds,
     * four decimal FPS*100 digits. Zero FPS means no >1s sample yet. */
    uint32_t model_id, inference_ms_bcd, result_fps_bcd;
} ai_frame_result;
enum ai_overlay_status { AI_OVERLAY_IDLE=0, AI_OVERLAY_RUN=1,
    AI_OVERLAY_LOAD=2, AI_OVERLAY_ERROR=3 };
#endif
