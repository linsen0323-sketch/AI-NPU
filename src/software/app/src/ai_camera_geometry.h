#ifndef AI_CAMERA_GEOMETRY_H
#define AI_CAMERA_GEOMETRY_H
/* Portable camera/model geometry; no MMIO, allocator or cache dependency. */
#define AI_RAW_WIDTH 1280u
#define AI_RAW_HEIGHT 720u
#define AI_RAW_BYTES (AI_RAW_WIDTH*AI_RAW_HEIGHT*2u)
#define AI_CAMERA_RESNET_WIDTH 160u
#define AI_CAMERA_YOLO_WIDTH 256u
#define AI_CAMERA_YOLO_HEIGHT 256u
#define AI_CAMERA_YOLO_CONTENT_HEIGHT 144u
#define AI_CAMERA_YOLO_CAMERA_SCALE (1280.0f / AI_CAMERA_YOLO_WIDTH)
#define AI_CAMERA_YOLO_PREDICTIONS 1344u
#define AI_CAMERA_YOLO_OUTPUT_BYTES 118272u
static inline int ai_camera_math_model_supported(unsigned model_id) {
    return model_id==1u || model_id==3u;
}
#endif
