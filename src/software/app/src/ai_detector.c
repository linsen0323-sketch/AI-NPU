#include "ai_detector.h"
#include <stddef.h>
#include <string.h>

static const char *const coco_names[80] = {
 "person","bicycle","car","motorcycle","airplane","bus","train","truck","boat","traffic light",
 "fire hydrant","stop sign","parking meter","bench","bird","cat","dog","horse","sheep","cow",
 "elephant","bear","zebra","giraffe","backpack","umbrella","handbag","tie","suitcase","frisbee",
 "skis","snowboard","sports ball","kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket","bottle",
 "wine glass","cup","fork","knife","spoon","bowl","banana","apple","sandwich","orange",
 "broccoli","carrot","hot dog","pizza","donut","cake","chair","couch","potted plant","bed",
 "dining table","toilet","tv","laptop","mouse","remote","keyboard","cell phone","microwave","oven",
 "toaster","sink","refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"
};
static const uint8_t coco_categories[80] = {
 1,2,3,4,5,6,7,8,9,10,11,13,14,15,16,17,18,19,20,21,22,23,24,25,27,28,31,32,33,34,
 35,36,37,38,39,40,41,42,43,44,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
 64,65,67,70,72,73,74,75,76,77,78,79,80,81,82,84,85,86,87,88,89,90
};
static const char *const neu_names[6] = {
 "crazing","inclusion","patches","pitted surface","rolled-in scale","scratches"
};
const char *ai_detector_class_name(uint32_t classes, uint32_t id) {
    if (id >= classes) return "unknown";
    return classes == 80u ? coco_names[id] : classes == 6u ? neu_names[id] : "unknown";
}
uint32_t ai_detector_coco_category(uint32_t id) { return id < 80u ? coco_categories[id] : 0u; }
static float low(float a,float b) { return a < b ? a : b; }
static float high(float a,float b) { return a > b ? a : b; }
static int better(const ai_detector_job *j,uint32_t a,uint32_t b) {
    const ai_detector_candidate *x=j->candidates+a,*y=j->candidates+b;
    return x->score > y->score || (x->score == y->score && x->index < y->index);
}
static void push(ai_detector_job *j,uint32_t index) {
    uint32_t c=j->heap_count++;
    while(c) { uint32_t p=(c-1u)/2u; if(!better(j,index,j->heap[p]))break; j->heap[c]=j->heap[p];c=p; }
    j->heap[c]=index;
}
static uint32_t pop(ai_detector_job *j) {
    uint32_t out=j->heap[0],last=j->heap[--j->heap_count],p=0;
    while(p*2u+1u<j->heap_count) {
        uint32_t c=p*2u+1u;
        if(c+1u<j->heap_count && better(j,j->heap[c+1u],j->heap[c]))++c;
        if(!better(j,j->heap[c],last))break;
        j->heap[p]=j->heap[c];p=c;
    }
    if(j->heap_count)j->heap[p]=last;
    return out;
}
static int suppress(const ai_detector_candidate *a,const ai_detector_candidate *b,float threshold) {
    float intersection,area;
    if(a->class_id!=b->class_id)return 0;
    intersection=high(0,low(a->x1,b->x1)-high(a->x0,b->x0))*high(0,low(a->y1,b->y1)-high(a->y0,b->y0));
    area=(a->x1-a->x0)*(a->y1-a->y0)+(b->x1-b->x0)*(b->y1-b->y0)-intersection;
    return area>0 && intersection/area>threshold;
}
int ai_detector_begin(ai_detector_job *j,const void *output,uint32_t bytes,
    uint32_t classes,float confidence,float nms) {
    if(!j || !output || ((uintptr_t)output&7u) || (classes!=6u && classes!=80u) ||
       bytes!=AI_DETECTOR_PREDICTIONS*(classes+5u)*8u ||
       !(confidence>=0 && confidence<=1 && nms>=0 && nms<=1))return -1;
    memset(j,0,offsetof(ai_detector_job,candidates));
    memset(&j->result,0,sizeof(j->result));
    j->output=output;j->classes=classes;j->confidence=confidence;j->nms=nms;
    j->display=ai_display_defaults();
    j->result.detection_mode=1;
    return 0;
}
int ai_detector_step(ai_detector_job *j,uint32_t budget,ai_frame_result *result) {
    if(!j || !j->output || !budget || !result)return -1;
    while(budget-- && !j->done) {
        if(j->phase==0) {
            const int64_t *p=j->output+j->row*(j->classes+5u);
            ai_detector_candidate c;
            float prob=(float)p[5]/65536.0f;
            ai_decoded_box box=ai_decode_box_q16(p);
            c.class_id=0;c.index=j->row;
            for(uint32_t k=1;k<j->classes;++k)if((float)p[k+5u]/65536.0f>prob) {
                prob=(float)p[k+5u]/65536.0f;c.class_id=k;
            }
            c.score=((float)p[4]/65536.0f)*prob;
            c.x0=box.x0;c.y0=box.y0;c.x1=box.x1;c.y1=box.y1;
            if(c.score>=j->confidence && p[2]>0 && p[3]>0) {
                uint32_t index=j->count++;j->candidates[index]=c;push(j,index);
            }
            if(++j->row==AI_DETECTOR_PREDICTIONS) {j->phase=1;j->count=0;}
        } else if(j->heap_count && j->count<8u) {
            ai_detector_candidate c=j->candidates[pop(j)];
            int rejected=0;
            for(uint32_t k=0;k<j->count && !rejected;++k)rejected=suppress(&c,j->selected+k,j->nms);
            if(!rejected)j->selected[j->count++]=c;
        } else {
            uint32_t visible=0;
            for(uint32_t k=0;k<j->count;++k) {
                ai_detector_candidate *c=j->selected+k;
                ai_decoded_box box={c->x0,c->y0,c->x1,c->y1};
                if(ai_display_box(j->result.boxes+visible,&box,c->score,c->class_id,&j->display))++visible;
            }
            j->result.box_count=(uint8_t)visible;
            if(visible) {j->result.class_id=j->result.boxes[0].class_id;j->result.score_pct=j->result.boxes[0].score_pct;}
            j->done=1;
        }
    }
    if(j->done) {*result=j->result;return 1;}
    return 0;
}
