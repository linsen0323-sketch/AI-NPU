/* Packed-RGB565 capture, independent live HDMI and asynchronous AI runtime.
 * Must run after matching PS7 DDR init and bitstream configuration.
 * Accepted snapshot/model/display leases are never revoked by a stream reset.
 */
#include <stdint.h>
#include <stddef.h>
#include "ai_preprocess.h"
#include "ai_camera_models.h"
#include "ai_camera_catalog.h"
#include "status_flags.h"
#include "ai_sd_boot.h"
#include "ai_coco80_config.h"
#include "ai_board_keys.h"
#include "ai_ps_timing.h"

#define CONTROL_BASE    0x41200000u
#define STATS_BASE      0x41210000u
#define UART_BASE       0xE0000000u
#define TIMER_BASE      0xF8F00200u
#define TIMER_HZ        333333333ull
#define DIAG_BASE       0x00F00000u
#define GPIO_DATA       0x00u
#define GPIO_TRI        0x04u
#define GPIO2_DATA      0x08u
#define GPIO2_TRI       0x0Cu

#ifndef AI_CAMERA_LOAD_FROM_SD
#define AI_CAMERA_LOAD_FROM_SD 0
#endif
#ifndef AI_CAMERA_BOOT_MODEL
#define AI_CAMERA_BOOT_MODEL 3u
#endif
/* In JTAG mode these are selectable candidates, not trusted resident bits.
 * Every unpinned selection must pass the manager's actual DDR CRC check. */
static uint32_t ai_available_models=AI_CAMERA_LOAD_FROM_SD ? 0u : AI_CAMERA_SUPPORTED_MASK;
/* Statistics update each second; UART emits a five-second summary.
 * Full status and the latest result are available on explicit L/R commands. */
static uint32_t status_dump_requested,result_dump_requested;
static uint32_t selected_model=AI_CAMERA_BOOT_MODEL,run_requested;
#define UART_SUMMARY_SECONDS 5u

enum runtime_state { ST_BOOT=1, ST_WAIT_SENSOR=2, ST_PRIMING=3,
    ST_RUNNING=4, ST_FATAL=5 };
enum fault_code { FAULT_NONE=0, FAULT_SENSOR=1, FAULT_CAPTURE=2,
    FAULT_NO_FRAMES=3, FAULT_AI_UNAVAILABLE=4 };
struct diagnostics {
    uint32_t magic, abi_version, state, heartbeat;
    uint32_t sensor_frames, good_frames, sensor_fps_x100, capture_fps_x100;
    uint32_t flags, fault, last_gpio_control, firmware_id;
    uint32_t timer_low, timer_high, snapshots, displayed_frames;
    uint32_t snapshot_fps_x100, display_fps_x100;
};
static volatile struct diagnostics *const diag =
    (volatile struct diagnostics *)(uintptr_t)DIAG_BASE;

static inline uint32_t read32(uint32_t address) {
    return *(volatile uint32_t *)(uintptr_t)address;
}
static inline void write32(uint32_t address,uint32_t value) {
    *(volatile uint32_t *)(uintptr_t)address=value;
    __asm__ volatile ("dsb sy" ::: "memory");
}
static uint64_t ticks(void) {
    uint32_t hi0,lo,hi1;
    do {
        hi0=read32(TIMER_BASE+4u); lo=read32(TIMER_BASE);
        hi1=read32(TIMER_BASE+4u);
    } while (hi0!=hi1);
    return ((uint64_t)hi1<<32)|lo;
}
static void timer_init(void) {
    write32(TIMER_BASE+8u,0u); write32(TIMER_BASE,0u);
    write32(TIMER_BASE+4u,0u); write32(TIMER_BASE+8u,1u);
}
static void uart_init(void) {
    write32(UART_BASE+0x0Cu,0x3FFFu);
    write32(UART_BASE,0x28u); write32(UART_BASE+4u,0x20u);
    write32(UART_BASE+0x18u,124u); write32(UART_BASE+0x34u,6u);
    write32(UART_BASE,0x2Bu);
    uint64_t start=ticks();
    while (read32(UART_BASE)&3u) if (ticks()-start>TIMER_HZ/10u) break;
    write32(UART_BASE+0x14u,0x3FFFu); write32(UART_BASE,0x14u);
}
static void putc_uart(char c) {
    uint64_t start=ticks();
    while (read32(UART_BASE+0x2Cu)&0x10u)
        if (ticks()-start>TIMER_HZ/50u) return;
    write32(UART_BASE+0x30u,(uint32_t)(unsigned char)c);
}
static void puts_uart(const char *s) { while (*s) putc_uart(*s++); }
static void print_u32(uint32_t value) {
    char digits[10]; uint32_t n=0;
    do { digits[n++]=(char)('0'+value%10u); value/=10u; } while (value);
    while (n) putc_uart(digits[--n]);
}
static void print_hex(uint32_t value) {
    const char *digits="0123456789ABCDEF";
    puts_uart("0x");
    for (int i=7;i>=0;--i) putc_uart(digits[(value>>(4u*(uint32_t)i))&15u]);
}
static void print_fps(uint32_t value) {
    print_u32(value/100u); putc_uart('.');
    putc_uart((char)('0'+(value/10u)%10u)); putc_uart((char)('0'+value%10u));
}
#if ENABLE_PS_TIMING
/* PST is a PS-only sidecar. No UART output is emitted during its capture
 * window; export runs only after the manager has safely reached STOPPED. */
static uint32_t ps_timing_quiet,ps_timing_dump_requested;
static uint64_t timing_clock(void *context) { (void)context;return ticks(); }
static void print_u64(uint64_t value) {
    char digits[20];uint32_t n=0;
    do {digits[n++]=(char)('0'+value%10u);value/=10u;}while(value);
    while(n)putc_uart(digits[--n]);
}
static uint64_t timing_us(uint64_t value,uint64_t hz) {
    return hz ? (value/hz)*1000000u+((value%hz)*1000000u)/hz : 0;
}
static uint64_t ps_us(uint64_t value) { return timing_us(value,ai_ps_timing_clock_hz()); }
static uint64_t gap_ticks(uint64_t wall,uint64_t work) {return wall>=work ? wall-work : 0;}
static void ps_timing_export(void) {
    if(!ps_timing_dump_requested || ai_camera_models_status()->state!=AI_CAMERA_STOPPED)return;
    ai_ps_timing_freeze();ps_timing_dump_requested=0;
    puts_uart("PST_BEGIN,version=1,ps_hz=");print_u64(ai_ps_timing_clock_hz());
    puts_uart(",rows=");print_u32(ai_ps_timing_count());puts_uart(",presented_valid=0\r\n");
    puts_uart("PST_COLUMNS,sample,model,frame,generation,task,flags,fault,npu_hz,pl_cycles,prepare_us,start_us,graph_us,post_us,publish_us,total_us,pl_us,prepare_cpu_us,post_cpu_us,publish_cpu_us,ui_cpu_us,prepare_polls,post_polls,copy_polls,copy_wait_us,copy_wall_us,copy_cpu_us,copy_gap_us,ui_render_us,ui_render_cpu_us,ui_render_gap_us,ui_submit_delay_us,ui_accept_us,result_to_submit_us,result_to_accept_us,ui_sequence,scan_submit,scan_accept,unique_submit,unique_accept,copy_valid,ui_valid,presented_valid,capture_gap_us,completion_interval_us,ui_accept_interval_us,interval_valid,ui_interval_valid\r\n");
    const ai_ps_timing_sample *previous=NULL;
    for(uint32_t i=0;i<ai_ps_timing_count();++i) {
        const ai_ps_timing_sample *s=ai_ps_timing_get(i);
        uint32_t cv=(s->flags&AI_PS_COPY_DONE)!=0,uv=(s->flags&AI_PS_UI_ACCEPTED)!=0;
        uint32_t good=(s->flags&AI_PS_PUBLISHED) && (s->flags&AI_PS_GRAPH_DONE) &&
            !(s->flags&AI_PS_ABORTED) && !s->fault;
        uint32_t iv=good && previous && s->model==previous->model && s->generation==previous->generation;
        uint32_t uiv=iv && uv && (previous->flags&AI_PS_UI_ACCEPTED);
        uint64_t cw=cv?s->copy_end-s->copy_begin:0,rw=uv?s->render_end-s->render_begin:0;
        const uint64_t values[]={s->sample,s->model,s->frame,s->generation,s->task,s->flags,s->fault,s->hz,s->graph_cycles,
            ps_us(s->phase[AI_PS_PREPARE]),ps_us(s->phase[AI_PS_START]),ps_us(s->phase[AI_PS_GRAPH]),
            ps_us(s->phase[AI_PS_POST]),ps_us(s->phase[AI_PS_PUBLISH]),ps_us(s->end-s->begin),
            (s->flags&AI_PS_GRAPH_DONE)?timing_us(s->graph_cycles,s->hz):0,
            ps_us(s->cpu[AI_PS_PREPARE]),ps_us(s->cpu[AI_PS_POST]),ps_us(s->cpu[AI_PS_PUBLISH]),ps_us(s->ui_cpu),
            s->prepare_polls,s->post_polls,s->copy_polls,cv?ps_us(s->copy_begin-s->copy_request):0,
            ps_us(cw),cv?ps_us(s->copy_cpu):0,cv?ps_us(gap_ticks(cw,s->copy_cpu)):0,
            ps_us(rw),uv?ps_us(s->render_cpu):0,uv?ps_us(gap_ticks(rw,s->render_cpu)):0,
            uv?ps_us(s->submit-s->render_end):0,uv?ps_us(s->accepted-s->submit):0,
            uv?ps_us(s->submit-s->end):0,uv?ps_us(s->accepted-s->end):0,
            s->ui_sequence,s->scan_submit,s->scan_accept,s->unique_submit,s->unique_accept,cv,uv,0,
            iv?ps_us(s->begin-previous->end):0,iv?ps_us(s->end-previous->end):0,
            uiv?ps_us(s->accepted-previous->accepted):0,iv,uiv};
        puts_uart("PST");
        for(uint32_t k=0;k<sizeof(values)/sizeof(values[0]);++k){putc_uart(',');print_u64(values[k]);}
        puts_uart("\r\n");
        previous=good?s:NULL;
    }
    puts_uart("PST_END\r\n");ps_timing_quiet=0;
}
#else
#define ps_timing_quiet 0u
#define ps_timing_export() ((void)0)
#endif
static void set_control(uint32_t value) {
    write32(CONTROL_BASE+GPIO_DATA,value); diag->last_gpio_control=value;
}
static uint32_t flags(void) { return read32(CONTROL_BASE+GPIO2_DATA); }
static uint32_t sensor_count(void) { return read32(STATS_BASE+GPIO_DATA); }
static uint32_t capture_count(void) { return read32(STATS_BASE+GPIO2_DATA); }
static void snapshot(void) {
    uint64_t now=ticks();
    diag->sensor_frames=sensor_count(); diag->good_frames=capture_count();
    diag->flags=flags(); diag->timer_low=(uint32_t)now; diag->timer_high=(uint32_t)(now>>32);
    __asm__ volatile ("dmb sy" ::: "memory");
}
/* PRF3 is a passive, one-shot PL snapshot. UART export is explicitly requested
 * after capture; use normal runs (without export) for PS/whole-frame timing. */
#define PROFILE_BASE (AI_PREPROCESS_BASE+0x8000u)
static uint32_t profile_dump_row,profile_dump_count;
static void profile_command(uint32_t c) {
    if (read32(PROFILE_BASE+0xE0u)!=0x50524633u) {
        puts_uart("PRF3 hardware unavailable\r\n"); return;
    }
    uint32_t status=read32(PROFILE_BASE+0xECu);
    if (c=='p' || c=='P') {
        if (status&(1u<<17)) { puts_uart("Profile capture running\r\n"); return; }
        profile_dump_count=0;
        write32(PROFILE_BASE+0xE0u,1u);
        puts_uart("Profile armed for next graph; press d after completion\r\n");
    } else if (status&(1u<<18)) {
        profile_dump_row=0;profile_dump_count=status&1023u;
        puts_uart("PROFILE frame=");print_u32(read32(PROFILE_BASE+0xF0u));
        puts_uart(" generation=");print_u32(read32(PROFILE_BASE+0xF4u));
        puts_uart(" task=");print_u32(read32(PROFILE_BASE+0xF8u));
        puts_uart(" hz=");print_u32(read32(PROFILE_BASE+0xD8u));
        puts_uart(" rows=");print_u32(profile_dump_count);
        puts_uart(" overflow=");print_u32((status>>19)&1u);
        puts_uart("\r\nLAYER_COLUMNS,index,cycles,pe_vectors,input_wait,output_wait,read_bytes,write_bytes,weight_loads,weight_hits\r\n");
    } else puts_uart("Profile not ready\r\n");
}
static void profile_export_step(void) {
    if (!profile_dump_count) return;
    puts_uart("LAYER");
    for (uint32_t word=0;word<8u;++word) {
        write32(PROFILE_BASE+0xE4u,profile_dump_row*8u+word);
        __asm__ volatile ("dmb sy" ::: "memory");
        uint32_t value=read32(PROFILE_BASE+0xE8u);
        puts_uart(",");print_u32(word==7u ? value&65535u : value);
        if (word==7u) { puts_uart(",");print_u32(value>>16); }
    }
    puts_uart("\r\n");
    if (++profile_dump_row==profile_dump_count) { profile_dump_count=0;puts_uart("PROFILE_END\r\n"); }
}

/* STL1 commands: i=arm index16, j=arm index273, s=dump frozen snapshot.
 * Request handling only sets software flags. MMIO/export waits for STOPPED
 * and an idle graph, so UART cannot stretch a measured model job. */
static uint32_t stall_arm_requested,stall_dump_requested;
static void stall_profile_step(void) {
    const volatile ai_camera_mailbox *m=ai_camera_models_status();
    if (m->state!=AI_CAMERA_STOPPED || (read32(PROFILE_BASE+0x0Cu)&1u)) return;
    if (!stall_arm_requested && !stall_dump_requested) return;
    if (!(read32(PROFILE_BASE+0xD4u)&16u)) {
        puts_uart("STL1 hardware unavailable (OPT1 bit4)\r\n");stall_arm_requested=stall_dump_requested=0;return;
    }
    if (read32(PROFILE_BASE+0x100u)!=UINT32_C(0x53544c31)) {
        puts_uart("STL1 hardware unavailable\r\n");stall_arm_requested=stall_dump_requested=0;return;
    }
    if (stall_arm_requested) {
        write32(PROFILE_BASE+0x104u,stall_arm_requested);
        __asm__ volatile ("dmb sy" ::: "memory");
        write32(PROFILE_BASE+0x108u,1u);
        write32(PROFILE_BASE+0xE0u,1u); /* PRF3 same next graph; format unchanged. */
        puts_uart("STL1 armed index=");print_u32(stall_arm_requested);
        puts_uart("; select model 3; stop with 0 before s\r\n");stall_arm_requested=0;
    }
    if (stall_dump_requested) {
        uint32_t st=read32(PROFILE_BASE+0x114u);
        stall_dump_requested=0;
        if (!(st&4u)) {puts_uart("STL1 not ready\r\n");return;}
        puts_uart("STALL status=");print_u32(st);
        static const uint32_t offsets[]={0x118u,0x11Cu,0x120u,0x124u,0x128u,0x12Cu,0xD8u};
        static const char *labels[]={" frame="," generation="," task="," model="," index="," fault="," hz="};
        for(uint32_t k=0;k<7u;++k){puts_uart(labels[k]);print_u32(read32(PROFILE_BASE+offsets[k]));}
        puts_uart("\r\nSTALL_COLUMNS,id,value,overflow\r\n");
        uint32_t count=read32(PROFILE_BASE+0x130u);
        if(count>85u)count=85u;
        for(uint32_t k=0;k<count;++k){
            write32(PROFILE_BASE+0x10Cu,k);__asm__ volatile ("dmb sy" ::: "memory");
            uint32_t value=read32(PROFILE_BASE+0x110u);
            write32(PROFILE_BASE+0x10Cu,k|128u);__asm__ volatile ("dmb sy" ::: "memory");
            uint32_t ov=read32(PROFILE_BASE+0x110u);
            puts_uart("STALL_COUNTER,");print_u32(k);puts_uart(",");print_u32(value);puts_uart(",");print_u32(ov);puts_uart("\r\n");
        }
        puts_uart("STALL_END\r\n");
    }
}

static int request_model(uint32_t id) {
    if (id && (!ai_camera_runtime_model(id) || diag->state==ST_FATAL ||
               !(ai_available_models&(1u<<(id-1u))))) {
        if(!ps_timing_quiet)puts_uart("AI model unavailable; request rejected.\r\n");
        return 0;
    }
    ai_camera_models_request(id);
    run_requested=id!=0;
    if (id) selected_model=id;
    if(!ps_timing_quiet) {
        puts_uart("AI requested: ");puts_uart(ai_camera_models_name(id));puts_uart("\r\n");
    }
    return 1;
}
static void service_board_keys(uint64_t now_ms) {
    uint32_t keys=ai_board_keys_poll(now_ms),selection=0;
    if(keys&AI_BOARD_KEY_RESNET)selection=1u;
    else if(keys&AI_BOARD_KEY_NEU)selection=3u;
    else if(keys&AI_BOARD_KEY_COCO)selection=AI_COCO80_LOGICAL_ID;
    if(selection && ai_camera_runtime_model(selection) &&
       (ai_available_models&(1u<<(selection-1u)))) {
        selected_model=selection;
        ai_camera_models_select_display(selection);
        if(!ps_timing_quiet){puts_uart("AI selected: ");puts_uart(ai_camera_models_name(selection));puts_uart("\r\n");}
    }
    /* The toggle edge takes priority over a simultaneous model-switch edge.
     * A stop drains/cancels through the existing manager; no reset or buffer
     * release is issued here. Presses during CRC/QUIESCE update intent safely. */
    if(keys&AI_BOARD_KEY_RUN)request_model(run_requested?0u:selected_model);
    else if(selection && run_requested && selection==selected_model &&
            ai_camera_models_status()->request_model!=selection)request_model(selection);
}
static void service_camera_models(uint64_t now) {
#if ENABLE_CAMERA_MODELS
    for (uint32_t n=0;n<8u && !(read32(UART_BASE+0x2Cu)&2u);++n) {
        uint32_t c=read32(UART_BASE+0x30u)&255u;
#if ENABLE_PS_TIMING
        if(c=='t' || c=='T') {
            if(profile_dump_count || stall_arm_requested || stall_dump_requested) {
                if(!ps_timing_quiet)puts_uart("PST: finish existing PRF/STL export first\r\n");
            } else if(ai_ps_timing_arm()) {
                /* A current unmeasured job may finish first. The next claim
                 * starts sample 1; no print occurs inside a sampled job. */
                if(!ps_timing_quiet)puts_uart("PST: armed next 20 jobs; wait, then 0 stop and O export\r\n");
                ps_timing_quiet=1;
            } else if(!ps_timing_quiet)puts_uart("PST: clock unavailable or capture busy\r\n");
            continue;
        }
        if(c=='o' || c=='O'){ps_timing_dump_requested=1;continue;}
        /* Quiet captures defer diagnostic output and reject disruptive UART
         * mode changes. Stop remains available and marks any live row aborted. */
        if(ps_timing_quiet && c!='0')continue;
#endif
        if (c=='l' || c=='L') status_dump_requested=1u;
        if (c=='r' || c=='R') result_dump_requested=1u;
        if (c=='i' || c=='I') stall_arm_requested=16u;
        if (c=='j' || c=='J') stall_arm_requested=273u;
        if (c=='s' || c=='S') stall_dump_requested=1u;
        if (c=='p' || c=='P' || c=='d' || c=='D') profile_command(c);
        if (c=='v' || c=='V') {
            ai_preprocess_stats view; ai_preprocess_get_stats(&view);
            ai_preprocess_set_matched(!view.matched_view);
            puts_uart(view.matched_view ? "View: live camera; result boxes hidden\r\n" : "View: matched inference source and boxes\r\n");
        }
        if (c>='0' && c<='4') request_model(c-'0');
    }
    service_board_keys(now/(TIMER_HZ/1000u));
    ai_camera_models_poll(now/(TIMER_HZ/1000u));
    if(ai_camera_models_status()->state==AI_CAMERA_ERROR)run_requested=0;
    if(!ps_timing_quiet){profile_export_step();stall_profile_step();}
    ps_timing_export();
#else
    (void)now;
#endif
}
static int start_capture(void) {
    /* No inference/HDMI-lock prerequisite: complete camera frames start scanout. */
    set_control(CTRL_STREAM_RESET_N); diag->state=ST_WAIT_SENSOR;
    uint64_t start=ticks();
    while ((flags()&(FLAG_SENSOR_READY|FLAG_STREAM_READY))!=
           (FLAG_SENSOR_READY|FLAG_STREAM_READY)) {
        if ((flags()&FLAG_SENSOR_ERROR) || ticks()-start>10u*TIMER_HZ) {
            diag->fault=FAULT_SENSOR; return 0;
        }
    }
    diag->state=ST_PRIMING;
    uint32_t first_capture=capture_count(); start=ticks();
    set_control(CTRL_STREAM_RESET_N|CTRL_CAPTURE_ENABLE|CTRL_DISPLAY_ENABLE);
    while (capture_count()-first_capture<3u) {
        if (flags()&FLAG_CAPTURE_ERROR) { diag->fault=FAULT_CAPTURE; return 0; }
        if (ticks()-start>5u*TIMER_HZ) { diag->fault=FAULT_NO_FRAMES; return 0; }
    }
    diag->state=ST_RUNNING; diag->fault=FAULT_NONE;
    puts_uart("CAPTURE running: RGB565 1280x720; HDMI shows latest complete camera frames; AI runs independently\r\n");
    return 1;
}
static void stop_capture(uint32_t fault) {
    /* Preserve accepted AXI transactions and leases until they drain. A failed
     * camera needs inspection/restart; resetting a live writer is unsafe. */
    set_control(CTRL_STREAM_RESET_N);
    diag->fault=fault; diag->state=ST_FATAL;
    ai_preprocess_set_capture(0); ai_preprocess_set_processed(0);
    ai_camera_models_request(0);run_requested=0;
    puts_uart("CAPTURE stopped; outstanding AI ownership retained. fault=");
    print_u32(fault); puts_uart("\r\n");
}
static void log_status(int ai_active) {
    puts_uart("sensor_fps="); print_fps(diag->sensor_fps_x100);
    puts_uart(" captured_fps="); print_fps(diag->capture_fps_x100);
    puts_uart(" snapshot_fps="); print_fps(diag->snapshot_fps_x100);
    puts_uart(" hdmi_stream_fps="); print_fps(diag->display_fps_x100);
    puts_uart(" flags="); print_hex(diag->flags);
    puts_uart(" fault="); print_u32(diag->fault);
    puts_uart(" capture_error="); print_u32((diag->flags>>12)&15u);
    puts_uart("\r\n");
    if (ai_active>0) {
        ai_preprocess_stats ai; ai_preprocess_get_stats(&ai);
        puts_uart("ai_snapshots="); print_u32(ai.snapshots);
        puts_uart(" ai_drop_sof="); print_u32(ai.dropped_sofs);
        puts_uart(" ai_fault="); print_hex(ai.fault);
        puts_uart(" ai_snapshot_error="); print_u32(ai.last_snapshot_error);
        puts_uart(" ai_results="); print_u32(ai.inferences);
        puts_uart(" ai_display_frames="); print_u32(ai.displayed_frames);
        puts_uart(" ai_display_fault="); print_hex(ai.display_fault);
        puts_uart(" ai_display_active="); print_u32(ai.processed_active);
        puts_uart(" overlay_valid="); print_u32(ai.overlay_valid);
        puts_uart(" boxes="); print_u32(ai.box_count);
        puts_uart(" max_score_pct="); print_u32(ai.max_score_pct);
        puts_uart(" result_frame="); print_u32(ai.result_frame);
        puts_uart(" result_age_ms="); print_u32(ai.result_age_ms);
        puts_uart(" publication_age_ms="); print_u32(ai.publication_age_ms);
        puts_uart(" matched_view="); print_u32(ai.matched_view);
        puts_uart("\r\n");
#if ENABLE_CAMERA_MODELS
        const volatile ai_camera_mailbox *camera=ai_camera_models_status();
        puts_uart("ai_model="); puts_uart(ai_camera_models_name(camera->active_model));
        puts_uart(" state="); print_u32(camera->state);
        puts_uart(" fault="); print_hex(camera->fault);
        puts_uart(" op="); print_u32(camera->graph_op);
        puts_uart(" done="); print_u32(camera->completed);
        puts_uart(" prepare_ms="); print_u32(camera->prepare_ms);
        puts_uart(" graph_ms="); print_u32(camera->graph_ms);
        puts_uart(" post_ms="); print_u32(camera->postprocess_ms);
        puts_uart(" total_ms="); print_u32(camera->total_ms);
        puts_uart(" discarded_graph_fault="); print_hex(camera->discarded_graph_fault);
        puts_uart(" switch_pending="); print_u32(camera->switch_pending);
        puts_uart("\r\n");
#endif
    }
}
/* Report completed switches and new faults once. Per-frame model states
 * (capture/prepare/run/postprocess) deliberately do not generate messages. */
static void log_model_events(void) {
#if ENABLE_CAMERA_MODELS
    static uint32_t last_ack=UINT32_MAX,last_fault;
    const volatile ai_camera_mailbox *m=ai_camera_models_status();
    if ((m->ack_seq!=last_ack && !m->switch_pending) || m->fault!=last_fault) {
        puts_uart("AI model="); print_u32(m->active_model);
        puts_uart(" state="); print_u32(m->state);
        puts_uart(" fault="); print_hex(m->fault);
        puts_uart(" switch_pending="); print_u32(m->switch_pending);
        puts_uart("\r\n");
        if (!m->switch_pending) last_ack=m->ack_seq;
        last_fault=m->fault;
    }
#endif
}
static void log_brief(int ai_active,uint32_t display_fps,uint32_t detection_fps) {
    puts_uart("STATUS cam_fps="); print_fps(diag->capture_fps_x100);
    if (ai_active>0) {
        puts_uart(" live_unique_fps="); print_fps(display_fps);
        puts_uart(" detection_fps="); print_fps(detection_fps);
#if ENABLE_CAMERA_MODELS
        const volatile ai_camera_mailbox *m=ai_camera_models_status();
        puts_uart(" model="); print_u32(m->active_model);
        puts_uart(" state="); print_u32(m->state);
        puts_uart(" done="); print_u32(m->completed);
        puts_uart(" graph_ms="); print_u32(m->graph_ms);
        puts_uart(" ai_fault="); print_hex(m->fault);
#endif
    }
    puts_uart(" fault="); print_u32(diag->fault); puts_uart("\r\n");
}
static void log_result(void) {
    ai_camera_detection_snapshot snapshot;
    if(!ai_camera_models_detection(&snapshot)) {
        puts_uart("RESULT unavailable (stopped, switching or no completed result)\r\n");return;
    }
    const ai_frame_result *r=&snapshot.result;
    puts_uart("RESULT model=");print_u32(snapshot.model_id);
    puts_uart(" frame=");print_u32(snapshot.frame_id);
    puts_uart(" generation=");print_u32(snapshot.generation);
    puts_uart(" classes=");print_u32(snapshot.classes);
    puts_uart(" class_id=");print_u32(r->class_id);
    puts_uart(" score_pct=");print_u32(r->score_pct);
    puts_uart(" boxes=");print_u32(r->box_count);puts_uart("\r\n");
    for(uint32_t k=0;k<r->box_count && k<8u;++k) {
        const ai_detection_box *b=&r->boxes[k];
        puts_uart("BOX,");print_u32(k);putc_uart(',');print_u32(b->class_id);
        putc_uart(',');print_u32(b->score_pct);putc_uart(',');print_u32(b->xmin);
        putc_uart(',');print_u32(b->ymin);putc_uart(',');print_u32(b->xmax);
        putc_uart(',');print_u32(b->ymax);puts_uart("\r\n");
    }
}
static void log_frontend_faults(const ai_preprocess_stats *ai) {
    static uint32_t last_fault,last_snapshot_error,last_display_fault;
    if (ai->fault!=last_fault || ai->last_snapshot_error!=last_snapshot_error ||
        ai->display_fault!=last_display_fault) {
        puts_uart("PL fault="); print_hex(ai->fault);
        puts_uart(" snapshot_error="); print_u32(ai->last_snapshot_error);
        puts_uart(" display_fault="); print_hex(ai->display_fault); puts_uart("\r\n");
        last_fault=ai->fault; last_snapshot_error=ai->last_snapshot_error;
        last_display_fault=ai->display_fault;
    }
}
void runtime_main(void) {
    timer_init();
#if ENABLE_PS_TIMING
    ai_ps_timing_init(timing_clock,NULL,TIMER_HZ);
#endif
    for (uint32_t i=0;i<sizeof(*diag)/4u;++i) ((volatile uint32_t *)diag)[i]=0u;
    diag->magic=0x37323050u; diag->abi_version=2u;
    diag->firmware_id=0x26110104u; diag->state=ST_BOOT;
    write32(CONTROL_BASE+GPIO_TRI,0u); write32(CONTROL_BASE+GPIO2_TRI,0xFFFFFFFFu);
    write32(STATS_BASE+GPIO_TRI,0xFFFFFFFFu); write32(STATS_BASE+GPIO2_TRI,0xFFFFFFFFu);
    set_control(0u); uart_init();
    puts_uart("Navigator live RGB565 HDMI runtime, ABI4/CAM2/LIV1\r\n");
    puts_uart("SOURCE_REV=npu100_ovl3_display_20261101_r3_timefix fw=0x26110104; matched boxes; timing=hw_or_ps\r\n");
    puts_uart("Snapshots 0x12000000..0x13C00000, 4MiB slots, 1843200 bytes/frame\r\n");
    int ai_active=ai_preprocess_init();
    int camera_status=ai_active>0 ? ai_camera_models_init() : -1;
    if (ai_active<=0 || camera_status<=0) {
        diag->fault=FAULT_AI_UNAVAILABLE; diag->state=ST_FATAL;
        puts_uart("AI frontend/model manager unavailable; capture remains stopped\r\n");
    } else {
        if (!start_capture()) stop_capture(diag->fault);
#if AI_CAMERA_LOAD_FROM_SD
        uint64_t stop_start=ticks();
        while (ai_camera_models_status()->state!=AI_CAMERA_STOPPED &&
               ai_camera_models_status()->state!=AI_CAMERA_ERROR && ticks()-stop_start<2u*TIMER_HZ)
            ai_camera_models_poll(ticks()/(TIMER_HZ/1000u));
        uint32_t mask=0;
        int loaded=-1;
        if (ai_camera_models_status()->state==AI_CAMERA_STOPPED) {
            loaded=ai_sd_boot_load(&mask);
        } else {
            puts_uart("SD preload blocked; camera state=");
            print_u32(ai_camera_models_status()->state);
            puts_uart(" fault="); print_hex(ai_camera_models_status()->fault);
            puts_uart("\r\n");
        }
        if (loaded==0 && (mask&AI_CAMERA_MODEL_MASK)==AI_CAMERA_MODEL_MASK &&
            !(mask&~AI_CAMERA_SUPPORTED_MASK) && ai_camera_models_set_resident_images(mask)>0) {
            ai_available_models=mask;
            puts_uart("SD models resident; UART 0 stop, 1 ResNet18, 3 YOLOX\r\n");
            if(mask&AI_COCO80_MASK)puts_uart("UART 4: YOLOX-S COCO80; R exports full result class IDs\r\n");
        } else {
            puts_uart("SD model load failed; live camera remains available, error=");
            print_hex((uint32_t)loaded); puts_uart("\r\n");
        }
#else
        puts_uart("JTAG: stage DDR packages before selection; UART 0 stop, 1 ResNet18, 3 YOLOX\r\n");
#if ENABLE_COCO80_CAMERA
        puts_uart("UART 4: YOLOX-S COCO80; stage_coco80.tcl loads its separate DDR slot\r\n");
#endif
        puts_uart("Unpinned selections verify the full actual DDR CRC before inference\r\n");
        puts_uart("Live camera display is independent of model selection\r\n");
#endif
    }
    if(ai_active>0 && ai_board_keys_init(ticks()/(TIMER_HZ/1000u))<0)
        puts_uart("Board keys unavailable: KEY1 hardware signature mismatch\r\n");
    if(!ai_camera_runtime_model(selected_model))selected_model=1u;
    run_requested=0;
    ai_camera_models_select_display(selected_model);
    puts_uart("AI stopped. KEY0/MIO12 ResNet; KEY1/MIO11 NEU6; KEY2/L14 COCO80; KEY3/K16 start-stop\r\n");
    puts_uart("UART: status every 5s; L full status; R last result; 0 stop, 1/3/4 select-and-run\r\n");
#if ENABLE_PS_TIMING
    puts_uart("PST PS timing: select/warm model, T captures next 20 jobs quietly; 0 then O exports CSV\r\n");
#endif
    uint64_t last_report=ticks(),last_progress=last_report,last_summary=last_report;
    uint32_t last_sensor=sensor_count(),last_good=capture_count(),progress_good=last_good;
    uint32_t last_snapshot=0,last_display=0,last_unique=0,last_results=0;
    uint32_t unique_fps=0,detection_fps=0;
    /* Preview has already run during SD loading. Start rates from current
     * counters, rather than reporting all boot frames as one second's work. */
    if (ai_active>0) {
        ai_preprocess_stats initial;
        ai_preprocess_get_stats(&initial);
        last_snapshot=initial.snapshots; last_display=initial.displayed_frames;
        last_unique=initial.unique_frames; last_results=initial.inferences;
    }
    for (;;) {
        uint64_t now=ticks();
        if (ai_active>0 && camera_status>0) service_camera_models(now);
        uint32_t good=capture_count();
        /* Timestamp camera progress after cooperative preprocessing. A
         * debugger halt must not turn an old counter sample into a timeout. */
        now=ticks();
        if (good!=progress_good) { progress_good=good; last_progress=now; }
        if (diag->state==ST_RUNNING) {
            if (flags()&FLAG_CAPTURE_ERROR) stop_capture(FAULT_CAPTURE);
            else if (now-last_progress>2u*TIMER_HZ) {
                /* A halt between the counter and timer reads must not turn
                 * an old counter sample into a fatal no-frame decision. */
                good=capture_count(); now=ticks();
                if (good!=progress_good) { progress_good=good; last_progress=now; }
                else stop_capture((flags()&FLAG_CAPTURE_ERROR) ? FAULT_CAPTURE : FAULT_NO_FRAMES);
            }
        }
        if (ai_active>0 && camera_status>0 && !ps_timing_quiet) log_model_events();
        if (result_dump_requested && !ps_timing_quiet) {
            result_dump_requested=0;log_result();
        }
        if (status_dump_requested && !ps_timing_quiet) {
            status_dump_requested=0;
            log_status(ai_active);
        }
        if (now-last_report>=TIMER_HZ) {
            uint32_t sensor=sensor_count(); uint64_t interval=now-last_report;
            diag->sensor_fps_x100=(uint32_t)((uint64_t)(sensor-last_sensor)*TIMER_HZ*100u/interval);
            diag->capture_fps_x100=(uint32_t)((uint64_t)(good-last_good)*TIMER_HZ*100u/interval);
            if (ai_active>0) {
                ai_preprocess_stats ai; ai_preprocess_get_stats(&ai);
                diag->snapshots=ai.snapshots; diag->displayed_frames=ai.displayed_frames;
                diag->snapshot_fps_x100=(uint32_t)((uint64_t)(ai.snapshots-last_snapshot)*TIMER_HZ*100u/interval);
                diag->display_fps_x100=(uint32_t)((uint64_t)(ai.displayed_frames-last_display)*TIMER_HZ*100u/interval);
                unique_fps=(uint32_t)((uint64_t)(ai.unique_frames-last_unique)*TIMER_HZ*100u/interval);
                detection_fps=(uint32_t)((uint64_t)(ai.inferences-last_results)*TIMER_HZ*100u/interval);
                if(!ps_timing_quiet)log_frontend_faults(&ai);
                last_unique=ai.unique_frames; last_results=ai.inferences;
                last_snapshot=ai.snapshots; last_display=ai.displayed_frames;
            }
            last_sensor=sensor; last_good=good; last_report=now;
            ++diag->heartbeat; snapshot();
            if (now-last_summary>=UART_SUMMARY_SECONDS*TIMER_HZ) {
                last_summary=now;
                if(!ps_timing_quiet)log_brief(ai_active,unique_fps,detection_fps);
            }
        }
    }
}
