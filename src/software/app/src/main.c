/*
 * OV5640 RGB565 camera inference application for Navigator Zynq-7020.
 * PL snapshots -> live HDMI; PS/shared NPU publish fresh-result overlays.
 *
 * Use the matching XSA/bitstream built from AI_NPU/npu100/project/npu100.xpr.
 * Vitis debug must initialize PS7 / DDR before calling main.
 * No lwIP, no network camera input. Optional PL snapshot/preprocessing support
 * is source-gated with ENABLE_PL_PREPROCESS; see npu100/source/acceleration.
 */
#include "xil_cache.h"
#include "xil_exception.h"
#include "ai_camera_memory.h"

void runtime_main(void);

int main(void)
{
    Xil_ExceptionDisableMask(XIL_EXCEPTION_ALL);
    Xil_ICacheEnable();
    /* Cache CPU-private code/data, keeping every HP DMA range uncached. */
    ai_camera_memory_init();
    runtime_main();
    while (1) { }
    return 0;
}
