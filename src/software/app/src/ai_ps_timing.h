#ifndef AI_PS_TIMING_H
#define AI_PS_TIMING_H
#include <stdint.h>
#ifndef ENABLE_PS_TIMING
#define ENABLE_PS_TIMING 0
#endif
#define AI_PS_TIMING_CAPACITY 20u
enum ai_ps_timing_phase { AI_PS_PREPARE, AI_PS_START, AI_PS_GRAPH,
    AI_PS_POST, AI_PS_PUBLISH, AI_PS_PHASES };
enum ai_ps_timing_flags { AI_PS_PUBLISHED=1u, AI_PS_ABORTED=2u,
    AI_PS_GRAPH_DONE=4u, AI_PS_COPY_DONE=8u, AI_PS_UI_ACCEPTED=16u };
/* Sidecar diagnostics only: existing CAM3 mailbox and all PL ABIs stay fixed.
 * Times below are raw ticks from a bound monotonic PS clock. Zero timestamp
 * validity is determined by flags/tokens, never by guessing a clock rate.
 * CPU work is included in phase wall time. Legacy copy/display fields remain
 * zero for compatibility with existing CSV analyzers; there are no UI workers.
 */
typedef struct {
    uint32_t sample, model, frame, generation, task, hz, flags, fault;
    uint32_t prepare_polls, post_polls, copy_polls, ui_polls;
    uint32_t ui_sequence, scan_submit, scan_accept, unique_submit, unique_accept;
    uint64_t begin, end, phase[AI_PS_PHASES], cpu[AI_PS_PHASES];
    uint64_t graph_start, graph_done, graph_cycles, ui_cpu;
    uint64_t copy_request, copy_begin, copy_end, copy_cpu;
    uint64_t render_begin, render_end, render_cpu, submit, accepted;
} ai_ps_timing_sample;
typedef uint64_t (*ai_ps_timing_clock)(void *);
#if ENABLE_PS_TIMING
void ai_ps_timing_init(ai_ps_timing_clock clock, void *context, uint64_t hz);
int ai_ps_timing_arm(void); /* capture next 20 jobs, never reset a live sample */
int ai_ps_timing_measuring(void);
uint64_t ai_ps_timing_now(void);
uint64_t ai_ps_timing_clock_hz(void);
void ai_ps_timing_begin(uint32_t model,uint32_t frame,uint32_t generation);
void ai_ps_timing_state(uint32_t camera_state);
void ai_ps_timing_work(enum ai_ps_timing_phase phase,uint64_t elapsed);
void ai_ps_timing_graph_start(uint32_t task,uint32_t hz);
void ai_ps_timing_graph_done(uint64_t cycles);
void ai_ps_timing_publish(void);
void ai_ps_timing_abort(uint32_t fault);
void ai_ps_timing_freeze(void);
uint32_t ai_ps_timing_count(void);
const ai_ps_timing_sample *ai_ps_timing_get(uint32_t index);
#else
static inline void ai_ps_timing_init(ai_ps_timing_clock c,void *p,uint64_t h){(void)c;(void)p;(void)h;}
static inline int ai_ps_timing_arm(void){return 0;}
static inline int ai_ps_timing_measuring(void){return 0;}
static inline uint64_t ai_ps_timing_now(void){return 0;}
static inline uint64_t ai_ps_timing_clock_hz(void){return 0;}
static inline void ai_ps_timing_begin(uint32_t m,uint32_t f,uint32_t g){(void)m;(void)f;(void)g;}
static inline void ai_ps_timing_state(uint32_t s){(void)s;}
static inline void ai_ps_timing_work(enum ai_ps_timing_phase p,uint64_t e){(void)p;(void)e;}
static inline void ai_ps_timing_graph_start(uint32_t t,uint32_t h){(void)t;(void)h;}
static inline void ai_ps_timing_graph_done(uint64_t c){(void)c;}
static inline void ai_ps_timing_publish(void){}
static inline void ai_ps_timing_abort(uint32_t f){(void)f;}
static inline void ai_ps_timing_freeze(void){}
static inline uint32_t ai_ps_timing_count(void){return 0;}
static inline const ai_ps_timing_sample *ai_ps_timing_get(uint32_t i){(void)i;return 0;}
#endif
#endif
