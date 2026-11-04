#include "ai_camera_math.h"
#include "ai_camera_luts.h"
#include "ai_camera_math_tables.h"
#include "ai_resnet_score_lut.h"
#include <string.h>
#include <stddef.h>

_Static_assert(sizeof(ai_resnet_exp_neg_q24)/sizeof(ai_resnet_exp_neg_q24[0])==256u,
               "Every signed INT8 logit difference requires one score term");
_Static_assert(AI_RESNET_SCORE_CLASSES==6u && AI_RESNET_SCORE_ONE_Q24==16777216u,
               "Confidence table must match the frozen six-class ResNet contract");
_Static_assert(103u*AI_RESNET_SCORE_ONE_Q24<=UINT32_MAX,
               "Softmax confidence numerator and rounded denominator must fit UINT32");

uint32_t ai_camera_prepare_scratch_bytes(uint32_t model_id)
{
    if (model_id == 1u) return AI_CAMERA_RESNET_WIDTH * AI_CAMERA_RESIZE_RING_ROWS * 3u;
    return 0u;
}

int ai_camera_prepare_begin(ai_camera_prepare_job *job, uint32_t model_id,
    const void *raw, void *tensor, void *scratch, uint32_t scratch_bytes)
{
    uint32_t needed = ai_camera_prepare_scratch_bytes(model_id);
    if (!job || !raw || !tensor || !ai_camera_math_model_supported(model_id) ||
        (needed && (!scratch || scratch_bytes < needed)) || ((uintptr_t)raw & 1u) ||
        (model_id != 1u && ((uintptr_t)tensor & 3u))) return -1;
    memset(job, 0, sizeof(*job));
    job->raw = (const uint8_t *)raw;
    job->tensor = (uint8_t *)tensor;
    job->scratch = (uint8_t *)scratch;
    job->model_id = model_id;
    job->width = model_id == 1u ? AI_CAMERA_RESNET_WIDTH : AI_CAMERA_YOLO_WIDTH;
    if(model_id==1u)job->source_row=ai_camera_resnet_y[0].first;
    return 0;
}

static uint8_t rounded_u8(uint32_t sum)
{
    sum >>= 22;
    return (uint8_t)(sum > 255u ? 255u : sum);
}

static uint32_t rgb565_channel(uint16_t pixel, uint32_t channel)
{
    uint32_t value;
    if (channel == 1u) {
        value = (pixel >> 5) & 63u;
        return (value << 2) | (value >> 4);
    }
    value = channel == 0u ? pixel >> 11 : pixel & 31u;
    return (value << 3) | (value >> 2);
}

static void horizontal(ai_camera_prepare_job *job)
{
    const ai_camera_axis *axis = ai_camera_resnet_x;
    const uint16_t *row = (const uint16_t *)(job->raw + job->source_row * AI_RAW_WIDTH * 2u);
    uint8_t *out = job->scratch + (job->source_row % AI_CAMERA_RESIZE_RING_ROWS) * job->width * 3u;
    uint32_t x, k;
    for (x = 0; x < job->width; ++x) {
        uint32_t red=1u<<21,green=1u<<21,blue=1u<<21;
        for(k=0;k<axis[x].count;++k) {
            /* Match the original sensor expansion before filtering. */
            uint32_t pixel=row[axis[x].first+k],weight=(uint32_t)axis[x].weight[k];
            red+=rgb565_channel((uint16_t)pixel,0u)*weight;
            green+=rgb565_channel((uint16_t)pixel,1u)*weight;
            blue+=rgb565_channel((uint16_t)pixel,2u)*weight;
        }
        out[x*3u]=rounded_u8(red);out[x*3u+1u]=rounded_u8(green);out[x*3u+2u]=rounded_u8(blue);
    }
}

static void vertical(ai_camera_prepare_job *job)
{
    const ai_camera_axis *axis = ai_camera_resnet_y;
    uint32_t x, c, k, plane = job->width * job->width;
    const ai_camera_axis *filter = &axis[job->row];
    for (x = 0; x < job->width; ++x) {
        for (c = 0; c < 3u; ++c) {
            uint32_t sum = 1u << 21;
            uint8_t pixel;
            for (k = 0; k < filter->count; ++k)
                sum += (uint32_t)job->scratch[
                    (((filter->first + k) % AI_CAMERA_RESIZE_RING_ROWS) * job->width + x) * 3u + c] *
                    (uint32_t)filter->weight[k];
            pixel = rounded_u8(sum);
            ((int8_t *)job->tensor)[c * plane + job->row * job->width + x] =
                ai_camera_resnet_quant[c][pixel];
        }
    }
}

static void yolo_row(ai_camera_prepare_job *job)
{
    int32_t *out=(int32_t *)job->tensor;
    const uint32_t width=AI_CAMERA_YOLO_WIDTH;
    const uint32_t plane=width*AI_CAMERA_YOLO_HEIGHT;
    const uint32_t scale=AI_RAW_WIDTH/width,center=(scale-1u)/2u;
    const uint32_t row_offset=job->row*width;
    /* Load each RGB565 source pixel once for all three channels. The camera
     * lease is immutable but uncached: a channel-major loop reread the same
     * source address three times. Keep exact BGR/Q16 and half-up rounding. */
    for(uint32_t x=0;x<width;++x) {
        uint32_t channel[3]={114u,114u,114u};
        if(job->row<AI_CAMERA_YOLO_CONTENT_HEIGHT) {
            const uint16_t *source=(const uint16_t *)job->raw+
                (job->row*scale+center)*AI_RAW_WIDTH+x*scale+center;
            uint16_t p0=source[0];
            uint16_t p1=0,p2=0,p3=0;
            if(!(scale&1u)) {
                p1=source[1];p2=source[AI_RAW_WIDTH];p3=source[AI_RAW_WIDTH+1u];
            }
            for(uint32_t c=0;c<3u;++c) {
                channel[c]=rgb565_channel(p0,2u-c);
                if(!(scale&1u))channel[c]=(channel[c]+rgb565_channel(p1,2u-c)+
                    rgb565_channel(p2,2u-c)+rgb565_channel(p3,2u-c)+2u)>>2;
            }
        }
        out[row_offset+x]=(int32_t)(channel[0]<<16);
        out[plane+row_offset+x]=(int32_t)(channel[1]<<16);
        out[2u*plane+row_offset+x]=(int32_t)(channel[2]<<16);
    }
}

int ai_camera_prepare_step(ai_camera_prepare_job *job, uint32_t max_rows)
{
    if (!job || !job->raw || !job->tensor || !max_rows ||
        !ai_camera_math_model_supported(job->model_id)) return -1;
    while (max_rows-- && job->phase != 2u) {
        if (job->model_id == 3u) {
            yolo_row(job);
            if (++job->row == AI_CAMERA_YOLO_HEIGHT) job->phase = 2u;
        } else {
            const ai_camera_axis *filter=ai_camera_resnet_y+job->row;
            if(filter->count>AI_CAMERA_RESIZE_RING_ROWS)return -1;
            if(job->source_row<filter->first)job->source_row=filter->first;
            if(job->source_row<filter->first+filter->count) {
                horizontal(job);++job->source_row;
            } else {
                vertical(job);
                if(++job->row==job->width)job->phase=2u;
            }
        }
    }
    return job->phase == 2u;
}

static float minimum(float a, float b) { return a < b ? a : b; }
static float maximum(float a, float b) { return a > b ? a : b; }

/* IoU is computed on original, unclipped decoded boxes, as in frozen host.py.
 * Screen clipping is a display-only operation after NMS. */
static int suppressed(const ai_camera_candidate *a, const ai_camera_candidate *b,float threshold)
{
    float width, height, intersection, area_a, area_b, union_area;
    if (a->class_id != b->class_id) return 0;
    width = maximum(0.0f, minimum(a->x1,b->x1) - maximum(a->x0,b->x0));
    height = maximum(0.0f, minimum(a->y1,b->y1) - maximum(a->y0,b->y0));
    intersection = width * height;
    area_a = (a->x1 - a->x0) * (a->y1 - a->y0);
    area_b = (b->x1 - b->x0) * (b->y1 - b->y0);
    union_area = area_a + area_b - intersection;
    return union_area > 0.0f && intersection / union_area > threshold;
}

static ai_camera_candidate prediction(const int64_t *p, uint32_t index)
{
    ai_camera_candidate c;
    uint32_t cls;
    ai_decoded_box box=ai_decode_box_q16(p);
    float class_score = (float)p[5] / 65536.0f;
    c.class_id = 0u;
    for (cls = 1u; cls < 6u; ++cls) {
        float next = (float)p[5u + cls] / 65536.0f;
        if (next > class_score) {class_score = next; c.class_id = cls;}
    }
    c.score = ((float)p[4] / 65536.0f) * class_score;
    c.x0=box.x0;c.y0=box.y0;c.x1=box.x1;c.y1=box.y1;
    c.index = index;
    return c;
}

static void finish_result(ai_camera_post_job *job)
{
    static const uint8_t overlay_class[6] = {0u,1u,3u,2u,4u,5u};
    uint32_t i, visible_count = 0u;
    for (i = 0; i < job->count; ++i) {
        const ai_camera_candidate *c = &job->selected[i];
        ai_decoded_box box={c->x0,c->y0,c->x1,c->y1};
        if(ai_display_box(&job->result.boxes[visible_count],&box,c->score,
                          overlay_class[c->class_id],&job->display))++visible_count;
    }
    job->result.box_count = (uint8_t)visible_count;
    if (visible_count) {
        job->result.class_id = job->result.boxes[0].class_id;
        job->result.score_pct = job->result.boxes[0].score_pct;
    }
    job->done = 1u;
}

int ai_camera_post_begin(ai_camera_post_job *job, uint32_t model_id,
    const void *output, uint32_t output_bytes)
{
    uint32_t needed = model_id == 1u ? 6u : AI_CAMERA_YOLO_OUTPUT_BYTES;
    if (!job || !output || !ai_camera_math_model_supported(model_id) ||
        output_bytes != needed ||
        (model_id == 3u && ((uintptr_t)output & 7u))) return -1;
    /* Entries beyond candidate_count/heap_count are not observed. */
    memset(job,0,offsetof(ai_camera_post_job,candidates));
    job->model_id = model_id; job->output = output;
    job->display=ai_display_defaults();
    job->nms=0.65f;
    job->result.detection_mode = model_id == 3u;
    job->best.score = -1.0f;
    return 0;
}

static int heap_better(const ai_camera_post_job *job,uint32_t a,uint32_t b)
{
    const ai_camera_candidate *left=&job->candidates[a],*right=&job->candidates[b];
    return left->score>right->score || (left->score==right->score && left->index<right->index);
}

static void heap_push(ai_camera_post_job *job,uint32_t candidate)
{
    uint32_t child=job->heap_count++;
    while(child) {
        uint32_t parent=(child-1u)>>1;
        if(!heap_better(job,candidate,job->heap[parent]))break;
        job->heap[child]=job->heap[parent];child=parent;
    }
    job->heap[child]=candidate;
}

static uint32_t heap_pop(ai_camera_post_job *job)
{
    uint32_t result=job->heap[0],last=job->heap[--job->heap_count],parent=0;
    while(parent*2u+1u<job->heap_count) {
        uint32_t child=parent*2u+1u;
        if(child+1u<job->heap_count && heap_better(job,job->heap[child+1u],job->heap[child]))++child;
        if(!heap_better(job,job->heap[child],last))break;
        job->heap[parent]=job->heap[child];parent=child;
    }
    if(job->heap_count)job->heap[parent]=last;
    return result;
}

static uint8_t resnet_confidence(const int8_t *logits,uint32_t best)
{
    uint32_t sum=0u;
    /* Stable softmax: common zero point cancels. The exact INT8 difference
     * lies in 0..255, so no exponential runtime/library or overflow is needed.
     * Six Q24 terms sum to <=100663296; 100*Q24+sum/2 fits UINT32. */
    for(uint32_t cls=0;cls<AI_RESNET_SCORE_CLASSES;++cls)
        sum+=ai_resnet_exp_neg_q24[(uint32_t)((int32_t)logits[best]-(int32_t)logits[cls])];
    return (uint8_t)((100u*AI_RESNET_SCORE_ONE_Q24+sum/2u)/sum);
}

int ai_camera_post_step(ai_camera_post_job *job, uint32_t max_predictions,
    ai_frame_result *result)
{
    if (!job || !job->output || !result || !max_predictions ||
        !ai_camera_math_model_supported(job->model_id) ||
        !(job->nms>=0.0f && job->nms<=1.0f)) return -1;
    if (job->model_id == 1u) {
        uint32_t cls, best = 0u;
        const int8_t *p = (const int8_t *)job->output;
        for (cls = 1u; cls < 6u; ++cls) {
            if (p[cls] > p[best]) best = cls;
        }
        job->result.class_id = (uint8_t)best;
        job->result.score_pct = resnet_confidence(p,best); job->done = 1u;
    }
    while (max_predictions-- && !job->done) {
        if(job->phase==0u) {
            ai_camera_candidate c=prediction((const int64_t *)job->output+job->row*11u,job->row);
            if(c.score>=0.01f && c.x1>c.x0 && c.y1>c.y0) {
                uint32_t index=job->candidate_count++;
                job->candidates[index]=c;heap_push(job,index);
            }
            if(++job->row==AI_CAMERA_YOLO_PREDICTIONS)job->phase=1u;
        } else if(!job->heap_count)finish_result(job);
        else {
            ai_camera_candidate c=job->candidates[heap_pop(job)];
            uint32_t k;int reject=0;
            for(k=0;k<job->count && !reject;++k)
                if(suppressed(&c,&job->selected[k],job->nms))reject=1;
            if(!reject)job->selected[job->count++]=c;
            if(job->count==8u)finish_result(job);
        }
    }
    if (job->done) {*result = job->result; return 1;}
    return 0;
}

int ai_camera_postprocess(uint32_t model_id, const void *output,
    uint32_t output_bytes, ai_frame_result *result)
{
    ai_camera_post_job job;
    int status = ai_camera_post_begin(&job,model_id,output,output_bytes);
    if (status < 0) return status;
    do {status = ai_camera_post_step(&job,256u,result);} while (status == 0);
    return status;
}
