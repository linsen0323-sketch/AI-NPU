#include "ai_display.h"

ai_decoded_box ai_decode_box_q16(const int64_t *p) {
    ai_decoded_box b;
    float cx=(float)p[0]/65536.0f,cy=(float)p[1]/65536.0f;
    float hw=((float)p[2]/65536.0f)/2.0f,hh=((float)p[3]/65536.0f)/2.0f;
    b.x0=cx-hw;b.y0=cy-hh;b.x1=cx+hw;b.y1=cy+hh;
    return b;
}
ai_display_options ai_display_defaults(void) {
    ai_display_options o={AI_DISPLAY_CONFIDENCE,AI_DISPLAY_MIN_WIDTH,AI_DISPLAY_MIN_HEIGHT};
    return o;
}
int ai_display_options_valid(const ai_display_options *o) {
    return o && o->confidence>=0.0f && o->confidence<=1.0f &&
        o->min_width>0u && o->min_width<=AI_RAW_WIDTH &&
        o->min_height>0u && o->min_height<=AI_RAW_HEIGHT;
}
static uint16_t pixel(float x,uint32_t limit,int upper) {
    uint16_t n;
    x*=AI_CAMERA_YOLO_CAMERA_SCALE;
    if(x<=0.0f)return 0u;
    if(x>=(float)limit)return (uint16_t)limit;
    n=(uint16_t)x;
    return (uint16_t)(n+(upper && (float)n<x));
}
int ai_display_box(ai_detection_box *out,const ai_decoded_box *b,float score,
                   uint32_t class_id,const ai_display_options *o) {
    ai_detection_box v;
    if(!out || !b || !ai_display_options_valid(o) || !(score>=o->confidence) ||
       !(b->x1>b->x0 && b->y1>b->y0) || b->x1<=0.0f || b->y1<=0.0f ||
       b->x0>=(float)AI_CAMERA_YOLO_WIDTH || b->y0>=(float)AI_CAMERA_YOLO_CONTENT_HEIGHT)return 0;
    v.xmin=pixel(b->x0,AI_RAW_WIDTH,0);v.ymin=pixel(b->y0,AI_RAW_HEIGHT,0);
    v.xmax=pixel(b->x1,AI_RAW_WIDTH,1);v.ymax=pixel(b->y1,AI_RAW_HEIGHT,1);
    if(v.xmax<=v.xmin || v.ymax<=v.ymin || v.xmax>AI_RAW_WIDTH || v.ymax>AI_RAW_HEIGHT ||
       v.xmax-v.xmin<o->min_width || v.ymax-v.ymin<o->min_height)return 0;
    v.class_id=(uint8_t)class_id;
    score=score*100.0f+0.5f;
    v.score_pct=(uint8_t)(score>100.0f?100.0f:score);
    *out=v;
    return 1;
}
uint32_t ai_decimal_bcd(uint32_t value,uint32_t digits) {
    uint32_t limit=1u,bcd=0u;
    if(digits==0u || digits>8u)return 0u;
    for(uint32_t k=0;k<digits;++k)limit*=10u;
    if(value>=limit)value=limit-1u;
    for(uint32_t k=0;k<digits;++k){bcd|=(value%10u)<<(k*4u);value/=10u;}
    return bcd;
}
void ai_result_metrics_reset(ai_result_metrics *m,uint64_t now_ms) {
    m->started_ms=now_ms;m->published=0u;m->fps_bcd=0u;
}
void ai_result_metadata(ai_frame_result *r,const ai_result_metrics *m,
                        uint32_t model,uint64_t graph_ms,uint64_t now_ms) {
    uint64_t elapsed=now_ms>=m->started_ms?now_ms-m->started_ms:0u;
    r->model_id=model;
    r->inference_ms_bcd=ai_decimal_bcd((uint32_t)(graph_ms>99999u?99999u:graph_ms),5u);
    r->result_fps_bcd=m->fps_bcd;
    if(elapsed>1000u) {
        uint64_t fps=((uint64_t)m->published+1u)*100000u/elapsed;
        r->result_fps_bcd=ai_decimal_bcd((uint32_t)(fps>9999u?9999u:fps),4u);
    }
}
void ai_result_metrics_commit(ai_result_metrics *m,const ai_frame_result *r) {
    if(m->published!=UINT32_MAX)++m->published;
    m->fps_bcd=r->result_fps_bcd;
}
