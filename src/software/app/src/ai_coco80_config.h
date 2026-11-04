#ifndef AI_COCO80_CONFIG_H
#define AI_COCO80_CONFIG_H
#include "ai_camera_catalog.h"

#ifndef ENABLE_COCO80_CAMERA
#define ENABLE_COCO80_CAMERA 0
#endif
#ifndef AI_CAMERA_LOAD_FROM_SD
#define AI_CAMERA_LOAD_FROM_SD 0
#endif
#define AI_COCO80_LOGICAL_ID 4u
#define AI_COCO80_MASK UINT32_C(8)
#if ENABLE_COCO80_CAMERA
/* PS selection 4 uses the existing YOLO ABI model family 3. The package is
 * unchanged; generation/base disambiguate it from NEU. This immutable slot
 * is outside camera, both existing images and the shared 8 MiB workspace. */
static const ai_camera_model_desc_t ai_coco80_model = {
    4u, "yolox_s_coco80_256", UINT32_C(0x1B000000), 15917056u,
    3646303270u, 15773696u, 143360u, 8126464u, 0u, 786432u,
    956928u, 913920u, 4u, 256u, 256u, 368u, 15u
};
#define AI_CAMERA_SUPPORTED_MASK (AI_CAMERA_MODEL_MASK | AI_COCO80_MASK)
#else
#define AI_CAMERA_SUPPORTED_MASK AI_CAMERA_MODEL_MASK
#endif
static inline const ai_camera_model_desc_t *ai_camera_runtime_model(uint32_t id)
{
#if ENABLE_COCO80_CAMERA
    if (id == AI_COCO80_LOGICAL_ID) return &ai_coco80_model;
#endif
    return ai_camera_model_find(id);
}
static inline uint32_t ai_camera_wire_model(uint32_t id)
{
    return id == AI_COCO80_LOGICAL_ID ? 3u : id;
}
#endif
