#include "ai_ps_timing.h"

#if ENABLE_PS_TIMING
#include <string.h>

/* The legacy export record retains zero-filled copy/display columns for
 * compatibility with captured CSV analyzers; the workers have been removed. */
enum { EVENT_GRAPH_START=64u };

static ai_ps_timing_sample samples[AI_PS_TIMING_CAPACITY];
static uint32_t events[AI_PS_TIMING_CAPACITY];
static ai_ps_timing_clock bound_clock;
static void *clock_context;
static uint64_t clock_hz, phase_begin;
static uint32_t used, active = AI_PS_TIMING_CAPACITY;
static enum ai_ps_timing_phase phase;
static int armed, frozen;

static ai_ps_timing_sample *active_sample(void)
{
    return !frozen && active < used ? &samples[active] : 0;
}

static void advance_phase(enum ai_ps_timing_phase next, uint64_t now)
{
    ai_ps_timing_sample *s = active_sample();
    if (s && next > phase && next < AI_PS_PHASES) {
        s->phase[phase] += now - phase_begin;
        phase_begin = now;
        phase = next;
    }
}

static void finish(uint32_t flag, uint32_t fault)
{
    ai_ps_timing_sample *s = active_sample();
    uint64_t now;
    if (!s) return;
    now = ai_ps_timing_now();
    s->phase[phase] += now - phase_begin;
    s->end = now;
    s->fault = fault;
    s->flags |= flag;
    active = AI_PS_TIMING_CAPACITY;
}

void ai_ps_timing_init(ai_ps_timing_clock clock, void *context, uint64_t hz)
{
    bound_clock = clock;
    clock_context = context;
    clock_hz = hz;
    memset(samples, 0, sizeof(samples));
    memset(events, 0, sizeof(events));
    used = 0;
    active = AI_PS_TIMING_CAPACITY;
    phase_begin = 0;
    phase = AI_PS_PREPARE;
    armed = frozen = 0;
}

int ai_ps_timing_arm(void)
{
    if (active < used || !bound_clock || !clock_hz) return 0;
    memset(samples, 0, sizeof(samples));
    memset(events, 0, sizeof(events));
    used = 0;
    active = AI_PS_TIMING_CAPACITY;
    phase = AI_PS_PREPARE;
    phase_begin = 0;
    frozen = 0;
    armed = 1;
    return 1;
}

int ai_ps_timing_measuring(void)
{
    return !frozen && ((armed && used < AI_PS_TIMING_CAPACITY) || active < used);
}

uint64_t ai_ps_timing_now(void)
{
    return bound_clock ? bound_clock(clock_context) : 0;
}

uint64_t ai_ps_timing_clock_hz(void)
{
    return clock_hz;
}

void ai_ps_timing_begin(uint32_t model, uint32_t frame, uint32_t generation)
{
    ai_ps_timing_sample *s;
    if (frozen || !armed || active < used || used >= AI_PS_TIMING_CAPACITY) return;
    active = used++;
    s = &samples[active];
    s->sample = active + 1u;
    s->model = model;
    s->frame = frame;
    s->generation = generation;
    s->begin = ai_ps_timing_now();
    phase_begin = s->begin;
    phase = AI_PS_PREPARE;
    if (used == AI_PS_TIMING_CAPACITY) armed = 0;
}

void ai_ps_timing_state(uint32_t camera_state)
{
    if (active_sample() && camera_state >= 6u && camera_state <= 10u) {
        enum ai_ps_timing_phase next = (enum ai_ps_timing_phase)(camera_state - 6u);
        if (next > phase) advance_phase(next, ai_ps_timing_now());
    }
}

void ai_ps_timing_work(enum ai_ps_timing_phase work_phase, uint64_t elapsed)
{
    ai_ps_timing_sample *s = active_sample();
    if (!s || (unsigned)work_phase >= AI_PS_PHASES) return;
    s->cpu[work_phase] += elapsed;
    if (work_phase == AI_PS_PREPARE) ++s->prepare_polls;
    else if (work_phase == AI_PS_POST) ++s->post_polls;
}

void ai_ps_timing_graph_start(uint32_t task, uint32_t hz)
{
    ai_ps_timing_sample *s = active_sample();
    uint64_t now;
    if (!s || (events[active] & EVENT_GRAPH_START)) return;
    now = ai_ps_timing_now();
    events[active] |= EVENT_GRAPH_START;
    s->task = task;
    s->hz = hz;
    s->graph_start = now;
    advance_phase(AI_PS_GRAPH, now);
}

void ai_ps_timing_graph_done(uint64_t cycles)
{
    ai_ps_timing_sample *s = active_sample();
    uint64_t now;
    if (!s || (s->flags & AI_PS_GRAPH_DONE)) return;
    now = ai_ps_timing_now();
    s->graph_done = now;
    s->graph_cycles = cycles;
    s->flags |= AI_PS_GRAPH_DONE;
    advance_phase(AI_PS_POST, now);
}

void ai_ps_timing_publish(void)
{
    finish(AI_PS_PUBLISHED, 0);
}

void ai_ps_timing_abort(uint32_t fault)
{
    finish(AI_PS_ABORTED, fault);
}

void ai_ps_timing_freeze(void)
{
    if (frozen) return;
    if (active_sample()) ai_ps_timing_abort(0);
    armed = 0;
    frozen = 1;
}

uint32_t ai_ps_timing_count(void)
{
    return used;
}

const ai_ps_timing_sample *ai_ps_timing_get(uint32_t index)
{
    return index < used ? &samples[index] : 0;
}
#endif
