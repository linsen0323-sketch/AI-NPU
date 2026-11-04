/* Camera frames and results use the PL's immutable manual leases. All models
 * execute on the existing single graph backend; the PS owns preprocessing,
 * model selection, classification/YOLO postprocessing and result publication.
 * No image/workspace is reused until graph completion has drained every AXI
 * transaction. A timed-out job retains its lease and workspace ownership.
 */
#include "ai_camera_models.h"
#include <stddef.h>
#include <string.h>
#include "ai_preprocess.h"
#include "ai_camera_catalog.h"
#include "ai_camera_math.h"
#include "ai_camera_memory.h"
#include "ai_coco80_config.h"
#include "ai_ps_timing.h"
#if ENABLE_COCO80_CAMERA
#include "ai_detector.h"
#endif

#if ENABLE_CAMERA_MODELS && ENABLE_PL_PREPROCESS
#ifndef AI_CAMERA_MODELS_TEST
static volatile ai_camera_mailbox *const mailbox =
    (volatile ai_camera_mailbox *)(uintptr_t)AI_CAMERA_MAILBOX_BASE;
static uint32_t rd(uint32_t address) { return *(volatile uint32_t *)(uintptr_t)address; }
static void barrier(void) { __asm__ volatile ("dmb sy" ::: "memory"); }
static void wr(uint32_t address,uint32_t value) {
    *(volatile uint32_t *)(uintptr_t)address=value; barrier();
}
static void invalidate(uint32_t address,uint32_t bytes) {
    (void)address; (void)bytes; barrier();
}
static void flush(uint32_t address,uint32_t bytes) {
    (void)address; (void)bytes; barrier();
}
#else
/* Native tests implement the same register/memory contract, without a board. */
extern volatile ai_camera_mailbox ai_camera_test_mailbox;
static volatile ai_camera_mailbox *const mailbox=&ai_camera_test_mailbox;
extern uint32_t ai_camera_test_read(uint32_t address);
extern void ai_camera_test_write(uint32_t address,uint32_t value);
static uint32_t rd(uint32_t address) { return ai_camera_test_read(address); }
static void wr(uint32_t address,uint32_t value) { ai_camera_test_write(address,value); }
static void barrier(void) { }
static void invalidate(uint32_t address,uint32_t bytes) { (void)address;(void)bytes; }
static void flush(uint32_t address,uint32_t bytes) { (void)address;(void)bytes; }
#endif

enum { G=0x43C18000u, CTRL=0x04u, MODE=0x08u, STATUS=0x0Cu,
       LAST_FAULT=0x30u, LAST_MODEL=0x34u, LAST_TASK=0x38u,
       LAST_FRAME=0x40u, LAST_GENERATION=0x44u, ACTIVE_TASK=0x50u,
       RESULT_ADDR=0x6Cu, RESULT_BYTES=0x70u, RESULT_DTYPE=0x74u,
       RESULT_VALID=0x78u };
enum { RAW_BYTES=AI_CAMERA_RAW_BYTES, CRC_WORDS_PER_POLL=1024u,
       PREPARE_STEPS_PER_POLL=16u };
static const ai_camera_model_desc_t *active, *target;
static ai_tensor_lease lease;
static ai_frame_result result;
static ai_camera_prepare_job prepare;
static ai_camera_post_job post;
#if ENABLE_COCO80_CAMERA
static ai_detector_job coco_post;
static float detector_nms=0.65f;
#endif
static ai_display_options display_options={AI_DISPLAY_CONFIDENCE,AI_DISPLAY_MIN_WIDTH,AI_DISPLAY_MIN_HEIGHT};
static ai_result_metrics result_metrics;
static uint32_t display_selected_model,graph_hz;
static int graph_hw_cycles_available;
static uint64_t graph_started_ms;
static uint64_t latest_poll_ms;
static ai_camera_detection_snapshot last_detection;
static int last_detection_valid;
static uint32_t scratch[(AI_CAMERA_PREPARE_SCRATCH_BYTES+3u)/4u];
static uint32_t crc_table[256], crc, crc_offset;
static uint32_t seen_seq, switching_seq, generation, expected_task;
static uint32_t task_frame, task_generation;
static uint32_t resident_pinned_mask;
static int initialized, have_lease, own_task, cancel_sent, invalidating;
static uint64_t entered_ms;
static uint64_t job_started_ms;
static int entry_clock_pending;

static uint32_t gr(uint32_t offset) { return rd(G+offset); }
static void gw(uint32_t offset,uint32_t value) { wr(G+offset,value); }
static enum ai_overlay_status overlay_state(uint32_t value) {
    if(value==AI_CAMERA_ERROR)return AI_OVERLAY_ERROR;
    if(value==AI_CAMERA_STOPPED || (value==AI_CAMERA_QUIESCE && !target))return AI_OVERLAY_IDLE;
    return value>=AI_CAMERA_CAPTURE && value<=AI_CAMERA_PUBLISH?AI_OVERLAY_RUN:AI_OVERLAY_LOAD;
}
static void state(uint32_t value) {
    ai_ps_timing_state(value);
    mailbox->state=value; entry_clock_pending=1;
    ai_preprocess_set_overlay_state(display_selected_model,overlay_state(value));
}
static int graph_quiet(void) {
    return !(gr(STATUS)&1u) && !(gr(CTRL)&0xBu) && !gr(RESULT_VALID) &&
           (gr(MODE)&4u);
}
static int release_lease(void) {
    if (!have_lease) return 1;
    if (ai_preprocess_release(&lease)!=1) return 0;
    have_lease=0; return 1;
}
static void fail(uint32_t why) {
    ai_ps_timing_abort(why);
    mailbox->fault=why;
    ai_preprocess_set_capture(0); ai_preprocess_set_processed(0);
    /* Never free input/output memory of a possibly live graph transaction. */
    if (!own_task && !release_lease()) mailbox->fault=AI_CAMERA_RELEASE_ERROR;
    state(AI_CAMERA_ERROR);
}
static int completion_identity(void) {
    return gr(LAST_TASK)==expected_task && gr(LAST_FRAME)==task_frame &&
           gr(LAST_GENERATION)==task_generation;
}
static int consume_done(int cancelling) {
    uint32_t status=gr(STATUS);
    if ((status&1u) || !(status&2u) || (gr(CTRL)&1u) || !gr(RESULT_VALID)) return 0;
    if (!completion_identity()) { fail(AI_CAMERA_BAD_RESULT); return -1; }
    uint32_t fault=gr(LAST_FAULT);
    /* The graph sequencer reports backend cancellation as 0x0406 as well
     * as its own 0x0405 or the task controller's 0x0301. Its backend detail
     * is not exposed by this ABI, so retain the exact terminal code instead
     * of classifying generic 0x0406 as harmless. A discarded task never
     * publishes output; the caller still waits for graph_quiet before reuse.
     * Ordinary (non-discarded) graph faults remain fatal below. */
    if (cancelling) mailbox->discarded_graph_fault=fault;
    if (!cancelling && (fault || !active || gr(LAST_MODEL)!=ai_camera_wire_model(active->id))) {
        /* This terminal descriptor is ours. Clear it after recording fault. */
        gw(CTRL,4u); own_task=0;
        fail(fault ? AI_CAMERA_GRAPH_FAULT|fault : AI_CAMERA_BAD_RESULT); return -1;
    }
    if (!cancelling &&
        (gr(RESULT_ADDR)!=AI_CAMERA_WORKSPACE_BASE+active->output_offset ||
         gr(RESULT_BYTES)!=active->output_bytes || gr(RESULT_DTYPE)!=active->output_dtype)) {
        gw(CTRL,4u); own_task=0; fail(AI_CAMERA_BAD_RESULT); return -1;
    }
    /* Keep disabled hardware cycles unavailable rather than inventing cycles
     * from a PS timestamp. Snapshot the submission-to-owned-DONE wall time
     * before ACK, output processing or publication can extend it. */
    mailbox->cycles_low=graph_hw_cycles_available?gr(0x48u):0u;
    mailbox->cycles_high=graph_hw_cycles_available?gr(0x4Cu):0u;
    if (!cancelling) {
        uint64_t cycles=((uint64_t)mailbox->cycles_high<<32)|mailbox->cycles_low;
        uint64_t ms=graph_hw_cycles_available?
            (cycles/graph_hz)*1000u+((cycles%graph_hz)*1000u)/graph_hz:
            (latest_poll_ms>=graph_started_ms?latest_poll_ms-graph_started_ms:0u);
        mailbox->graph_ms=(uint32_t)(ms>UINT32_MAX?UINT32_MAX:ms);
        ai_ps_timing_graph_done(cycles);
    }
    gw(CTRL,4u); own_task=0; return 1;
}
static void begin_switch(uint32_t id,uint32_t seq) {
    ai_ps_timing_abort(0); /* An interrupted sample is never a completed result. */
    switching_seq=seq;
    target=ai_camera_runtime_model(id);
    if(id)display_selected_model=id;
    ai_result_metrics_reset(&result_metrics,latest_poll_ms);
    mailbox->cycles_low=0;mailbox->cycles_high=0;mailbox->graph_ms=0;
    last_detection_valid=0;
    mailbox->switch_pending=1u; mailbox->fault=0;
    ai_preprocess_set_capture(0); ai_preprocess_set_processed(0);
    cancel_sent=0; state(AI_CAMERA_QUIESCE);
}

int ai_camera_models_init(void) {
    memset((void *)mailbox,0,sizeof(*mailbox));
    mailbox->magic=AI_CAMERA_MAILBOX_MAGIC; mailbox->abi=1;
    active=NULL; target=NULL; initialized=0; have_lease=0; own_task=0;
    cancel_sent=0; invalidating=0; seen_seq=0; switching_seq=0;
    generation=0; expected_task=0; task_frame=0; task_generation=0;resident_pinned_mask=0;
    display_selected_model=0;graph_hz=0;latest_poll_ms=0;
    graph_hw_cycles_available=0;graph_started_ms=0;
    ai_result_metrics_reset(&result_metrics,0u);
    last_detection_valid=0;
    for (uint32_t n=0;n<256u;++n) {
        uint32_t v=n;
        for (uint32_t b=0;b<8u;++b) v=(v>>1)^((0u-(v&1u))&UINT32_C(0xEDB88320));
        crc_table[n]=v;
    }
    if (!ai_camera_memory_uncached() || !ai_preprocess_raw_supported() ||
        gr(0)!=UINT32_C(0x4E475031) || gr(0x88u)!=2u ||
        gr(0xD0u)!=UINT32_C(0x4F505431) ||
        (gr(0xD4u)&AI_CAMERA_REQUIRED_PLAN_FEATURES)!=AI_CAMERA_REQUIRED_PLAN_FEATURES ||
        ((gr(0xD4u)^AI_CAMERA_REQUIRED_PLAN_FEATURES)&2u)!=0u ||
        gr(0xDCu)!=(AI_CAMERA_MODEL_MASK<<1)) {
        mailbox->fault=AI_CAMERA_BAD_ABI; state(AI_CAMERA_ERROR); return -1;
    }
    /* A restart may encounter another caller's result. Do not consume it. */
    if (!graph_quiet() || (ai_preprocess_drain_status()&0x1Cu)) {
        mailbox->fault=AI_CAMERA_FOREIGN_OWNER; state(AI_CAMERA_ERROR); return -1;
    }
    initialized=1;
    gw(0x84u,0); wr(AI_PREPROCESS_BASE+0x100u,0);
    begin_switch(0,0); return 1;
}

static int request_allowed(uint32_t model_id) {
    if (model_id && !ai_camera_runtime_model(model_id)) return 0;
    /* SD admission requires the loader's verified immutable image. JTAG
     * admission instead goes through QUIESCE -> VERIFY, reading actual DDR
     * and checking the full package CRC before any configuration or task. */
    if (AI_CAMERA_LOAD_FROM_SD && model_id==AI_COCO80_LOGICAL_ID &&
        !(resident_pinned_mask&AI_COCO80_MASK)) return 0;
    return 1;
}

void ai_camera_models_request(uint32_t model_id) {
    if (!initialized || !request_allowed(model_id)) return;
    mailbox->request_model=model_id; barrier();
    mailbox->request_seq=mailbox->request_seq+1u; barrier();
}
int ai_camera_models_select_display(uint32_t model_id) {
    if(!ai_camera_runtime_model(model_id))return -1;
    enum ai_overlay_status overlay=overlay_state(mailbox->state);
    if(model_id!=display_selected_model && overlay==AI_OVERLAY_RUN)overlay=AI_OVERLAY_LOAD;
    display_selected_model=model_id;
    return ai_preprocess_set_overlay_state(model_id,overlay);
}

int ai_camera_models_set_resident_images(uint32_t verified_mask) {
    if(!initialized || mailbox->state!=AI_CAMERA_STOPPED || own_task || have_lease ||
       !graph_quiet() || (verified_mask&~AI_CAMERA_SUPPORTED_MASK))return -1;
    resident_pinned_mask=verified_mask;mailbox->verified_model_mask=verified_mask;
    barrier();return 1;
}

void ai_camera_models_poll(uint64_t now_ms) {
    if (!initialized) return;
    latest_poll_ms=now_ms;
    uint32_t seq=mailbox->request_seq;
    barrier(); uint32_t request=mailbox->request_model; barrier();
    if (seq==mailbox->request_seq && seq!=seen_seq) {
        seen_seq=seq;
        if (!request_allowed(request)) {
            mailbox->fault=AI_CAMERA_BAD_REQUEST; mailbox->ack_seq=seq;
        } else begin_switch(request,seq);
    }
    if (entry_clock_pending) { entered_ms=now_ms; entry_clock_pending=0; }
    uint32_t frontend_fault=rd(AI_PREPROCESS_BASE+0x1Cu);
    if (frontend_fault && mailbox->state!=AI_CAMERA_ERROR) {
        fail(AI_CAMERA_FRONTEND_FAULT|frontend_fault);
    }
    mailbox->graph_op=gr(0x3Cu);
    switch (mailbox->state) {
    case AI_CAMERA_STOPPED: break;
    case AI_CAMERA_QUIESCE:
        if (own_task) {
            if (!cancel_sent && ((gr(STATUS)&1u) || (gr(CTRL)&1u))) {
                gw(CTRL,2u); cancel_sent=1;
            }
            int done=consume_done(1);
            if (done<0) break;
            if (!done) {
                if (now_ms-entered_ms>60000u) fail(AI_CAMERA_TIMEOUT);
                break;
            }
        }
        if (!graph_quiet()) {
            if (now_ms-entered_ms>60000u) fail(AI_CAMERA_FOREIGN_OWNER);
            break;
        }
        if (!release_lease()) { fail(AI_CAMERA_RELEASE_ERROR); break; }
        if (ai_preprocess_discard_pending()!=1) {
            if (now_ms-entered_ms>60000u) fail(AI_CAMERA_TIMEOUT);
            break;
        }
        if (ai_preprocess_camera_mode(1)!=1) { fail(AI_CAMERA_BAD_CONFIGURATION); break; }
        active=NULL; mailbox->active_model=0;
        gw(0x84u,0); gw(MODE,1u);
        if ((gr(MODE)&7u)!=7u) break;
        if (!target) {
            mailbox->ack_seq=switching_seq; mailbox->switch_pending=0;
            state(AI_CAMERA_STOPPED); break;
        }
        if(resident_pinned_mask&(1u<<(target->id-1u))) {
            // Loader owns all writes to these immutable model slots. Only the
            // execution/metadata caches must be invalidated on a switch.
            invalidating=0;state(AI_CAMERA_INVALIDATE);break;
        }
        crc=UINT32_C(0xFFFFFFFF); crc_offset=0;
        mailbox->verified_model_mask&=~(1u<<(target->id-1u));
        invalidate(target->model_base,target->image_bytes);
        state(AI_CAMERA_VERIFY); break;
    case AI_CAMERA_VERIFY: {
        uint32_t end=crc_offset+CRC_WORDS_PER_POLL*4u;
        if (end>target->image_bytes) end=target->image_bytes;
        for (;crc_offset<end;crc_offset+=4u) {
            uint32_t v=rd(target->model_base+crc_offset);
            for (uint32_t b=0;b<4u;++b) {
                crc=(crc>>8)^crc_table[(crc^v)&255u]; v>>=8;
            }
        }
        if (crc_offset==target->image_bytes) {
            if ((crc^UINT32_C(0xFFFFFFFF))!=target->image_crc) { fail(AI_CAMERA_BAD_CRC); break; }
            mailbox->verified_model_mask|=1u<<(target->id-1u);
            invalidating=0; state(AI_CAMERA_INVALIDATE);
        }
        break;
    }
    case AI_CAMERA_INVALIDATE:
        if (!invalidating) {
            if (!graph_quiet() || (gr(MODE)&7u)!=7u) { fail(AI_CAMERA_FOREIGN_OWNER); break; }
            gw(CTRL,8u); invalidating=1;
        } else if (!(gr(CTRL)&8u)) state(AI_CAMERA_CONFIGURE);
        if (now_ms-entered_ms>5000u) fail(AI_CAMERA_TIMEOUT);
        break;
    case AI_CAMERA_CONFIGURE: {
        if (!graph_quiet() || (gr(MODE)&7u)!=7u) { fail(AI_CAMERA_FOREIGN_OWNER); break; }
        generation=gr(0x2Cu)+1u; if (!generation) generation=1u;
        const uint32_t offsets[]={0x10u,0x14u,0x18u,0x1Cu,0x20u,0x24u,0x28u,0x2Cu,
                                  0x60u,0x64u,0x68u,0x7Cu,0x80u};
        const uint32_t values[]={target->model_base,target->image_bytes,
            AI_CAMERA_WORKSPACE_BASE,target->workspace_bytes,
            target->model_base+target->plan_offset,target->plan_bytes,0,generation,
            AI_CAMERA_WORKSPACE_BASE+target->output_offset,target->output_bytes,target->output_dtype,
            AI_CAMERA_WORKSPACE_BASE+target->input_offset,target->input_bytes};
        int valid=1;
        for (size_t i=0;i<sizeof(offsets)/sizeof(offsets[0]);++i) gw(offsets[i],values[i]);
        for (size_t i=0;i<sizeof(offsets)/sizeof(offsets[0]);++i) if (gr(offsets[i])!=values[i]) valid=0;
        if (!valid) { fail(AI_CAMERA_BAD_CONFIGURATION); break; }
        active=target; mailbox->active_model=active->id; mailbox->generation=generation;
        mailbox->ack_seq=switching_seq; mailbox->switch_pending=0;
        ai_preprocess_set_capture(1); state(AI_CAMERA_CAPTURE); break;
    }
    case AI_CAMERA_CAPTURE: {
        int claimed=ai_preprocess_claim(&lease);
        if (claimed<0) { fail(AI_CAMERA_BAD_LEASE); break; }
        if (!claimed) break;
        have_lease=1;
        job_started_ms=now_ms;
        ai_ps_timing_begin(active->id,lease.frame_id,generation);
        if (lease.raw_address<0x12000000u || lease.raw_address>=0x14000000u ||
            ((lease.raw_address-0x12000000u)&0x3FFFFFu) ||
            lease.address!=lease.raw_address || lease.bytes!=RAW_BYTES) {
            fail(AI_CAMERA_BAD_LEASE); break;
        }
        mailbox->frame_id=lease.frame_id;
        if (ai_camera_prepare_begin(&prepare,ai_camera_wire_model(active->id),(const void *)(uintptr_t)lease.raw_address,
              (void *)(uintptr_t)(AI_CAMERA_WORKSPACE_BASE+active->input_offset),
              scratch,sizeof(scratch))<0) { fail(AI_CAMERA_MATH_ERROR); break; }
        state(AI_CAMERA_PREPARE); break;
    }
    case AI_CAMERA_PREPARE: {
        uint64_t work_start=ai_ps_timing_now();
        int done=ai_camera_prepare_step(&prepare,PREPARE_STEPS_PER_POLL);
        ai_ps_timing_work(AI_PS_PREPARE,ai_ps_timing_now()-work_start);
        if (done<0) { fail(AI_CAMERA_MATH_ERROR); break; }
        if (done) {
            mailbox->prepare_ms=(uint32_t)(now_ms-entered_ms);
            flush(AI_CAMERA_WORKSPACE_BASE+active->input_offset,active->input_bytes);
            state(AI_CAMERA_START);
        }
        break;
    }
    case AI_CAMERA_START: {
        if (!graph_quiet() || (gr(MODE)&7u)!=7u) { fail(AI_CAMERA_FOREIGN_OWNER); break; }
        gw(0x28u,lease.frame_id);
        if (gr(0x28u)!=lease.frame_id || gr(0x2Cu)!=generation) { fail(AI_CAMERA_BAD_CONFIGURATION); break; }
        expected_task=gr(ACTIVE_TASK)+1u; task_frame=lease.frame_id; task_generation=generation;
        /* DIA bit2 advertises the optional task-cycle counter. Compact PL
         * disables it, so OSD timing must then use the independent PS clock.
         * The polling clock is available even when ENABLE_PS_TIMING is 0. */
        graph_hz=gr(0xD8u);
        if(!graph_hz){fail(AI_CAMERA_BAD_CONFIGURATION);break;}
        uint32_t diagnostic_features=gr(0xFCu);
        graph_hw_cycles_available=(diagnostic_features&UINT32_C(0xFFFFFF00))==UINT32_C(0x44494100) &&
            (diagnostic_features&4u)!=0u;
        mailbox->cycles_low=0;mailbox->cycles_high=0;mailbox->graph_ms=0;
        ai_ps_timing_graph_start(expected_task,graph_hz);
        graph_started_ms=now_ms;
        own_task=1; cancel_sent=0; gw(CTRL,1u); state(AI_CAMERA_RUNNING); break;
    }
    case AI_CAMERA_RUNNING: {
        int done=consume_done(0);
        if (done<0) break;
        if (done) {
            invalidate(AI_CAMERA_WORKSPACE_BASE+active->output_offset,active->output_bytes);
#if ENABLE_COCO80_CAMERA
            if (active->id==AI_COCO80_LOGICAL_ID) {
                if (ai_detector_begin(&coco_post,
                    (const void *)(uintptr_t)(AI_CAMERA_WORKSPACE_BASE+active->output_offset),
                    active->output_bytes,80u,0.01f,detector_nms)<0) {
                    fail(AI_CAMERA_MATH_ERROR); break;
                }
                coco_post.display=display_options;
            } else
#endif
            if (ai_camera_post_begin(&post,active->id,
                  (const void *)(uintptr_t)(AI_CAMERA_WORKSPACE_BASE+active->output_offset),active->output_bytes)<0) {
                fail(AI_CAMERA_MATH_ERROR); break;
            }
            if(active->id!=AI_COCO80_LOGICAL_ID)post.display=display_options;
            state(AI_CAMERA_POSTPROCESS);
        } else if (now_ms-entered_ms>900000u) fail(AI_CAMERA_TIMEOUT);
        break;
    }
    case AI_CAMERA_POSTPROCESS: {
        uint64_t work_start=ai_ps_timing_now();
        int done;
#if ENABLE_COCO80_CAMERA
        if (active->id==AI_COCO80_LOGICAL_ID) done=ai_detector_step(&coco_post,128u,&result);
        else
#endif
        done=ai_camera_post_step(&post,128u,&result);
        ai_ps_timing_work(AI_PS_POST,ai_ps_timing_now()-work_start);
        if (done<0) { fail(AI_CAMERA_MATH_ERROR); break; }
        if (done) { mailbox->postprocess_ms=(uint32_t)(now_ms-entered_ms); state(AI_CAMERA_PUBLISH); }
        break;
    }
    case AI_CAMERA_PUBLISH: {
        uint64_t work_start=ai_ps_timing_now();
        ai_result_metadata(&result,&result_metrics,active->id,mailbox->graph_ms,now_ms);
        const ai_frame_result *legacy=&result;
#if ENABLE_COCO80_CAMERA
        ai_frame_result preview;
        /* The existing PL label ABI has only three class bits. Preserve
         * COCO geometry, detection mode and scores, but send class7 for a
         * neutral white "--" label instead of a misleading NEU class.
         * The immutable full 0..79 IDs remain in result/snapshot/UART R. */
        if (active->id==AI_COCO80_LOGICAL_ID) {
            preview=result;preview.class_id=7u;
            for(uint32_t k=0;k<preview.box_count && k<8u;++k)
                preview.boxes[k].class_id=7u;
            legacy=&preview;
        }
#endif
        if (ai_preprocess_publish(&lease,legacy)!=1) { fail(AI_CAMERA_BAD_RESULT); break; }
        ai_result_metrics_commit(&result_metrics,&result);
        last_detection.result=result;
        last_detection.model_id=active->id;
        last_detection.classes=active->id==AI_COCO80_LOGICAL_ID ? 80u : 6u;
        last_detection.frame_id=lease.frame_id;last_detection.generation=task_generation;
        last_detection_valid=1;
        mailbox->total_ms=(uint32_t)(now_ms-job_started_ms);
        have_lease=0; ++mailbox->completed;
        ai_preprocess_set_processed(1);
        ai_ps_timing_work(AI_PS_PUBLISH,ai_ps_timing_now()-work_start);
        ai_ps_timing_publish();
        state(AI_CAMERA_CAPTURE); break;
    }
    case AI_CAMERA_ERROR:
        /* Cancel/drain our timed-out job, keeping ownership if it is wedged.
         * No repeated START, reset, foreign-result clear, or DDR overwrite. */
        if (own_task) {
            if (!cancel_sent && ((gr(STATUS)&1u) || (gr(CTRL)&1u))) { gw(CTRL,2u); cancel_sent=1; }
            if (consume_done(1)>0 && !release_lease()) mailbox->fault=AI_CAMERA_RELEASE_ERROR;
        }
        break;
    default: fail(AI_CAMERA_BAD_CONFIGURATION); break;
    }
    barrier();
}

const volatile ai_camera_mailbox *ai_camera_models_status(void) { return mailbox; }
int ai_camera_models_detection(ai_camera_detection_snapshot *out) {
    if (!out || !last_detection_valid) return 0;
    *out=last_detection;
    /* NEU's legacy overlay swaps source classes 2 and 3. UART results use
     * source order; never alter the already published result descriptor. */
    if(out->model_id==3u) {
        if(out->result.class_id==2u || out->result.class_id==3u)out->result.class_id^=1u;
        for(uint32_t n=0;n<out->result.box_count;++n)
            if(out->result.boxes[n].class_id==2u || out->result.boxes[n].class_id==3u)
                out->result.boxes[n].class_id^=1u;
    }
    return 1;
}
int ai_camera_models_set_thresholds(float confidence,float nms) {
    if (!(confidence>=0.0f && confidence<=1.0f && nms>=0.0f && nms<=1.0f)) return -1;
    display_options.confidence=confidence;
#if ENABLE_COCO80_CAMERA
    detector_nms=nms;
#endif
    return 1;
}
int ai_camera_models_set_display(const ai_display_options *options) {
    if(!ai_display_options_valid(options))return -1;
    display_options=*options;return 1;
}
#else
static ai_camera_mailbox disabled_mailbox;
int ai_camera_models_init(void) { return 0; }
int ai_camera_models_set_resident_images(uint32_t verified_mask) { (void)verified_mask;return -1; }
void ai_camera_models_request(uint32_t id) { (void)id; }
int ai_camera_models_select_display(uint32_t id) { (void)id;return -1; }
void ai_camera_models_poll(uint64_t now_ms) { (void)now_ms; }
const volatile ai_camera_mailbox *ai_camera_models_status(void) { return &disabled_mailbox; }
int ai_camera_models_detection(ai_camera_detection_snapshot *out) { (void)out;return 0; }
int ai_camera_models_set_thresholds(float confidence,float nms) { (void)confidence;(void)nms;return -1; }
int ai_camera_models_set_display(const ai_display_options *o) { (void)o;return -1; }
#endif

const char *ai_camera_models_name(uint32_t model_id) {
    const ai_camera_model_desc_t *model=ai_camera_runtime_model(model_id);
    return model ? model->name : model_id ? "unsupported" : "stopped";
}
