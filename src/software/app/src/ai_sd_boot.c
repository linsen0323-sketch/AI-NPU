#include "ai_sd_boot.h"
#ifndef AI_CAMERA_LOAD_FROM_SD
#define AI_CAMERA_LOAD_FROM_SD 0
#endif
#if AI_CAMERA_LOAD_FROM_SD
#include "ff.h"
#include "npu_sd_loader.h"
#include "xil_printf.h"
#include "ai_coco80_config.h"
static FATFS ai_sd_filesystem;
int ai_sd_boot_load(uint32_t *resident_mask)
{
    FRESULT fs;
    if(!resident_mask)return NPU_SD_MANIFEST;
    *resident_mask=0;
    xil_printf("SD: mounting 0:/\r\n");
    fs=f_mount(&ai_sd_filesystem,"0:/",1);
    if(fs!=FR_OK) {
        xil_printf("SD: f_mount(0:/) failed, FRESULT=%d.\r\n",(int)fs);
        return NPU_SD_FILESYSTEM;
    }
    xil_printf("SD: mounted 0:/; loading models from 0:/npu.\r\n");
    /* Keep the filesystem mounted for the lifetime of the application. */
    int result=npu_sd_preload("0:/npu",resident_mask);
    if(result)return result;
#if ENABLE_COCO80_CAMERA
    uint32_t coco_mask=0;
    int coco_result=npu_sd_preload_coco80("0:/npu",&coco_mask);
    if(coco_result==NPU_SD_OK)*resident_mask|=coco_mask;
    else xil_printf("SD: optional COCO80 unavailable (%d); original models retained.\r\n",coco_result);
#endif
    return NPU_SD_OK;
}
#else
int ai_sd_boot_load(uint32_t *resident_mask)
{
    if(!resident_mask)return -2;
    *resident_mask=0;
    return 1;
}
#endif
