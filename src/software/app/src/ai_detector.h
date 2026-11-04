#ifndef AI_DETECTOR_H
#define AI_DETECTOR_H
#include <stdint.h>
#include "ai_display.h"

#define AI_DETECTOR_PREDICTIONS 1344u
#define AI_DETECTOR_MAX_CLASSES 80u
typedef struct {
    float x0, y0, x1, y1, score;
    uint32_t index, class_id;
} ai_detector_candidate;
typedef struct {
    const int64_t *output;
    uint32_t classes, row, count, heap_count, phase, done;
    float confidence, nms;
    ai_detector_candidate candidates[AI_DETECTOR_PREDICTIONS];
    uint32_t heap[AI_DETECTOR_PREDICTIONS];
    ai_detector_candidate selected[8];
    ai_frame_result result;
    ai_display_options display;
} ai_detector_job;

/* Decoded/sigmoid INT64 Q16 [1,1344,5+classes], COCO80 or NEU6.
 * Input must remain owned until completion. Class IDs stay in source order;
 * these results must not be sent to the legacy 3-bit NEU label interface.
 * Camera coordinates use the existing 256x256 top-left letterbox contract.
 * confidence admits NMS candidates; job.display independently filters the
 * final display after NMS, with the same default policy as NEU.
 */
int ai_detector_begin(ai_detector_job *job, const void *output, uint32_t bytes,
    uint32_t classes, float confidence, float nms);
int ai_detector_step(ai_detector_job *job, uint32_t budget, ai_frame_result *result);
const char *ai_detector_class_name(uint32_t classes, uint32_t id);
uint32_t ai_detector_coco_category(uint32_t id);
#endif
