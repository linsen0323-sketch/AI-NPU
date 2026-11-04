#ifndef AI_CAMERA_MATH_H
#define AI_CAMERA_MATH_H
#include <stdint.h>
#include "ai_display.h"

/* Fixed camera contract: 1280x720 tightly packed little-endian RGB565;
 * bits 15:11=R, 10:5=G, 4:0=B. Channels expand by bit replication only
 * when sampled for the existing model preprocessing.
 * Source, tensor and scratch allocations must be disjoint and remain leased
 * until prepare completes (and tensor until the graph has drained). No MMIO,
 * cache maintenance or allocation is performed by these routines. */
#define AI_CAMERA_RAW_BYTES AI_RAW_BYTES
#define AI_CAMERA_RESIZE_RING_ROWS 32u
#define AI_CAMERA_PREPARE_SCRATCH_BYTES (AI_CAMERA_RESNET_WIDTH * AI_CAMERA_RESIZE_RING_ROWS * 3u)
#if (1280u % AI_CAMERA_YOLO_WIDTH) || (720u % AI_CAMERA_YOLO_CONTENT_HEIGHT) || (1280u / AI_CAMERA_YOLO_WIDTH != 720u / AI_CAMERA_YOLO_CONTENT_HEIGHT)
#error "YOLO camera resize requires the same integer scale on both axes"
#endif
typedef struct {
    const uint8_t *raw;
    uint8_t *tensor, *scratch;
    uint32_t model_id, row, phase, width, source_row;
} ai_camera_prepare_job;

uint32_t ai_camera_prepare_scratch_bytes(uint32_t model_id);
/* IDs: 1 ResNet18, 3 YOLOX-S A; ID 2 is unsupported. Tensor capacities must be
 * at least 160*160*3 bytes for model 1 or 256*256*3*sizeof(int32_t) for model 3. Model 3's
 * tensor is aligned to 4 bytes. Returns 0 on accepted initialization, -1 on invalid input. */
int ai_camera_prepare_begin(ai_camera_prepare_job *job, uint32_t model_id,
    const void *raw, void *tensor, void *scratch, uint32_t scratch_bytes);
/* At most max_rows source/output rows per call; 1 complete, 0 pending, -1 error.
 * Caller should service video/switch events between calls. */
int ai_camera_prepare_step(ai_camera_prepare_job *job, uint32_t max_rows);

typedef struct {
    float x0, y0, x1, y1, score;
    uint32_t index, class_id;
} ai_camera_candidate;
typedef struct {
    const void *output;
    uint32_t model_id, row, count, done, candidate_count, heap_count, phase;
    ai_camera_candidate best, selected[8];
    ai_frame_result result;
    ai_display_options display;
    float nms; /* Class-aware IoU threshold; defaults to the original 0.65. */
    /* Decode once, then exact score/index-ordered greedy NMS. The original
     * O(8*N) full DDR/Q16 decode scans become one scan and a max heap. */
    ai_camera_candidate candidates[AI_CAMERA_YOLO_PREDICTIONS];
    uint32_t heap[AI_CAMERA_YOLO_PREDICTIONS];
} ai_camera_post_job;

/* Classification returns exact signed argmax (ties choose first) and rounded
 * softmax confidence of its six INT8 logits using their frozen output scale.
 * The display score is 0..100; class selection/model execution are unchanged.
 * YOLO output is already
 * decoded/sigmoid INT64 Q16 [AI_CAMERA_YOLO_PREDICTIONS,11].
 * Greedy class-aware NMS retains score>=0.01 and defaults to frozen-host
 * IoU>0.65. Set job.nms after post_begin to configure the IoU threshold;
 * the first 8 kept boxes pass display-only confidence/minimum-size filtering
 * after clipping to the camera frame. Original decoded geometry and NMS stay
 * unchanged; tiny/offscreen boxes are rejected, never enlarged. Source class IDs 2/3 are
 * remapped to the overlay's PS/Pa order after NMS. Allocation stays valid until
 * post_step returns 1. No graph/control ownership is changed by these APIs. */
int ai_camera_post_begin(ai_camera_post_job *job, uint32_t model_id,
    const void *output, uint32_t output_bytes);
/* At most max_predictions YOLO candidates examined per call. Classification
 * completes in one call. 1 complete (writes result), 0 pending, -1 error. */
int ai_camera_post_step(ai_camera_post_job *job, uint32_t max_predictions,
    ai_frame_result *result);
/* Blocking convenience for host checks; the runtime should use row-step APIs. */
int ai_camera_postprocess(uint32_t model_id, const void *output,
    uint32_t output_bytes, ai_frame_result *result);
#endif
