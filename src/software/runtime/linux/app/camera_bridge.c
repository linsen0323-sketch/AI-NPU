/* SPDX-License-Identifier: MIT
 * Portable RGB565 preprocessing and existing Q16 postprocessing for Linux.
 * No MMIO, physical pointers, cache operations or hardware ownership here.
 * Buffers remain leased by the caller until every step finishes.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "ai_camera_math.h"
#include "ai_detector.h"
#include "ai_display.h"

typedef struct {
    uint32_t model;
    float nms;
    ai_display_options display;
    ai_camera_prepare_job prepare;
    union { ai_camera_post_job neu; ai_detector_job coco; } post;
    ai_frame_result result;
    uint32_t scratch[(AI_CAMERA_PREPARE_SCRATCH_BYTES+3u)/4u];
} camera_context;

uint32_t npu_camera_bridge_abi(void) { return 3u; }

void *npu_camera_new(uint32_t model,float confidence,uint32_t minimum,float nms)
{
    camera_context *c;
    ai_display_options options={confidence,(uint16_t)minimum,(uint16_t)minimum};
    if ((model!=1u && model!=3u && model!=4u) || minimum>720u ||
        !ai_display_options_valid(&options) || !(nms>=0.0f && nms<=1.0f)) return NULL;
    c=calloc(1,sizeof(*c));
    if(c) {c->model=model;c->display=options;c->nms=nms;}
    return c;
}

void npu_camera_free(void *context) { free(context); }

int npu_camera_prepare_begin(void *context,const void *raw,uint32_t raw_bytes,
                             void *input,uint32_t input_bytes)
{
    camera_context *c=context;
    uint32_t required;
    if(!c || raw_bytes!=AI_RAW_BYTES) return -1;
    required=c->model==1u ? 76800u : 786432u;
    if(input_bytes!=required) return -1;
    /* Both YOLO packages use the same frozen 256x256 preprocessing. */
    return ai_camera_prepare_begin(&c->prepare,c->model==4u?3u:c->model,
        raw,input,c->scratch,sizeof(c->scratch));
}

int npu_camera_prepare_step(void *context,uint32_t budget)
{
    camera_context *c=context;
    return c?ai_camera_prepare_step(&c->prepare,budget):-1;
}

int npu_camera_post_begin(void *context,const void *output,uint32_t bytes)
{
    camera_context *c=context;
    int status;
    if(!c) return -1;
    memset(&c->result,0,sizeof(c->result));
    if(c->model==4u) {
        status=ai_detector_begin(&c->post.coco,output,bytes,80u,0.01f,c->nms);
        if(!status)c->post.coco.display=c->display;
    } else {
        status=ai_camera_post_begin(&c->post.neu,c->model,output,bytes);
        if(!status){c->post.neu.display=c->display;c->post.neu.nms=c->nms;}
    }
    return status;
}

int npu_camera_post_step(void *context,uint32_t budget)
{
    camera_context *c=context;
    if(!c)return -1;
    return c->model==4u?ai_detector_step(&c->post.coco,budget,&c->result):
        ai_camera_post_step(&c->post.neu,budget,&c->result);
}

/* Explicit words avoid ctypes/C structure padding and ABI-dependent floats.
 * [class,score,detection,count], then eight [xmin,ymin,xmax,ymax,class,score]. */
int npu_camera_result(void *context,uint32_t *words,uint32_t capacity)
{
    camera_context *c=context;
    if(!c || !words || capacity<52u)return -1;
    memset(words,0,52u*sizeof(*words));
    words[0]=c->result.class_id;words[1]=c->result.score_pct;
    words[2]=c->result.detection_mode;words[3]=c->result.box_count;
    for(uint32_t i=0;i<c->result.box_count && i<8u;++i) {
        const ai_detection_box *b=c->result.boxes+i;
        uint32_t *w=words+4u+i*6u;
        w[0]=b->xmin;w[1]=b->ymin;w[2]=b->xmax;w[3]=b->ymax;
        w[4]=b->class_id;w[5]=b->score_pct;
    }
    return 0;
}
