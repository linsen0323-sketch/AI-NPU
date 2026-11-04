#ifndef CAMERA720P_STATUS_FLAGS_H
#define CAMERA720P_STATUS_FLAGS_H
/* Final top-level AXI GPIO channel 2 status map. */
#define FLAG_SENSOR_READY  (1u << 0)
#define FLAG_SENSOR_ERROR  (1u << 1)
#define FLAG_NACK_HISTORY  (1u << 2)
#define FLAG_CAPTURE_HISTORY ((1u << 3) | (1u << 4))
/* Bits 3/4 survive a stream-only reset; bit 5 is the current fault latch
 * acknowledged by stream_resetn. History must not prevent a fresh start. */
#define FLAG_CAPTURE_ERROR (1u << 5)
#define FLAG_STREAM_READY  (1u << 6)
#define FLAG_CAPTURE_ACTIVE (1u << 7)
#define FLAG_VIDEO_LOCKED  (1u << 8)
#define FLAG_VIDEO_UNDERFLOW (1u << 9)
#define FLAG_VIDEO_OVERFLOW (1u << 10)
#define FLAG_HDMI_LOCKED   (1u << 11)
#define CTRL_CAPTURE_ENABLE  (1u << 0)
#define CTRL_STREAM_RESET_N  (1u << 1)
#define CTRL_DISPLAY_ENABLE  (1u << 2)
/* NACK history and video startup underflow are diagnostic, not fatal. */
#endif
