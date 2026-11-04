#ifndef AI_DISPLAY_H
#define AI_DISPLAY_H
#include "ai_result.h"
#include "ai_camera_geometry.h"
#ifndef AI_DISPLAY_CONFIDENCE
#define AI_DISPLAY_CONFIDENCE 0.25f
#endif
#ifndef AI_DISPLAY_MIN_WIDTH
#define AI_DISPLAY_MIN_WIDTH 6u
#endif
#ifndef AI_DISPLAY_MIN_HEIGHT
#define AI_DISPLAY_MIN_HEIGHT 6u
#endif
typedef struct { float confidence; uint16_t min_width, min_height; } ai_display_options;
typedef struct { float x0,y0,x1,y1; } ai_decoded_box;
/* Successful completed-result average since start/switch, including startup. */
typedef struct { uint64_t started_ms; uint32_t published, fps_bcd; } ai_result_metrics;
/* Graph already emits sigmoid/decoded Q16 cx,cy,w,h. No second grid/exp. */
ai_decoded_box ai_decode_box_q16(const int64_t *prediction);
ai_display_options ai_display_defaults(void);
int ai_display_options_valid(const ai_display_options *options);
/* Display only, after original NMS. Rejects tiny clipped boxes; never expands. */
int ai_display_box(ai_detection_box *out,const ai_decoded_box *box,float score,
                   uint32_t class_id,const ai_display_options *options);
uint32_t ai_decimal_bcd(uint32_t value,uint32_t digits);
void ai_result_metrics_reset(ai_result_metrics *metrics,uint64_t now_ms);
/* Prepare includes this prospective successful publication; caller commits
 * counters only after its atomic result publication succeeds. graph_ms is
 * already selected from available PL cycles or monotonic host elapsed time. */
void ai_result_metadata(ai_frame_result *result,const ai_result_metrics *metrics,
                        uint32_t model,uint64_t graph_ms,uint64_t now_ms);
void ai_result_metrics_commit(ai_result_metrics *metrics,const ai_frame_result *result);
#endif
