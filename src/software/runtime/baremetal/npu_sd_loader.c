// SPDX-License-Identifier: MIT
/* Source-only FatFs cold-boot loader for the current standalone Cortex-A9 BSP.
 * Uses a binary companion generated with the JSON SD bundle. Frozen artifacts
 * remain read-only; all file handles use FA_READ. No workspace/Golden staging.
 */
#include "npu_sd_loader.h"
#include "npu_sd_hash.h"
#include "ai_camera_catalog.h"
#include "ff.h"
#ifdef SDT
#include "xiltimer.h"
#else
#include "xtime_l.h"
#endif
#include "sleep.h"
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifndef ENABLE_COCO80_CAMERA
#define ENABLE_COCO80_CAMERA 0
#endif
#if ENABLE_COCO80_CAMERA
#include "ai_coco80_config.h"
#endif

#define F_BASE UINT32_C(0x43c10000)
#define G_BASE UINT32_C(0x43c18000)
#define SD_HEADER 256u
#define SD_RECORD 320u
#define SD_COUNT AI_CAMERA_MODEL_COUNT
#define SD_MANIFEST (SD_HEADER+SD_RECORD*SD_COUNT)
typedef struct {
    uint32_t id,base,bytes,crc,plan_offset,plan_bytes,workspace_bytes;
    uint32_t input_offset,input_bytes,output_offset,output_bytes,dtype;
    uint32_t width,height,ops,features;
    uint8_t sha[32];
    char name[80],file[112];
} sd_model;
#if defined(NPU_SD_LOADER_TEST)
extern uint32_t npu_sd_test_read(uint32_t address);
extern void npu_sd_test_write(uint32_t address,uint32_t value);
extern void *npu_sd_test_pointer(uint32_t address);
static uint32_t read32(uint32_t address) { return npu_sd_test_read(address); }
static void fence(void) { }
static void write32(uint32_t address,uint32_t value) { npu_sd_test_write(address,value); }
static void *ddr_pointer(uint32_t address) { return npu_sd_test_pointer(address); }
#else
static uint32_t read32(uint32_t address) { return *(volatile uint32_t *)(uintptr_t)address; }
static void fence(void) { __asm__ volatile("dmb sy" ::: "memory"); }
static void write32(uint32_t address,uint32_t value) { *(volatile uint32_t *)(uintptr_t)address=value;fence(); }
static void *ddr_pointer(uint32_t address) { return (void *)(uintptr_t)address; }
#endif
static uint32_t little32(const uint8_t *p) { return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static uint32_t checksum(const void *p,size_t size) { return npu_crc32_update(UINT32_MAX,p,size)^UINT32_MAX; }
static int uncached(void)
{
#if defined(NPU_SD_LOADER_TEST)
    return 1;
#else
    uint32_t sctlr;
    __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(sctlr));
    return !(sctlr&4u) && !(read32(0xf8f02100u)&1u);
#endif
}
static int legal_name(const char *name,size_t capacity)
{
    size_t i;
    for(i=0;i<capacity && name[i];++i) {
        unsigned char c=(unsigned char)name[i];
        if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.'))return 0;
    }
    return i>0 && i<capacity && strcmp(name,".") && strcmp(name,"..");
}
static int make_path(char out[256],const char *root,const char *file)
{
    int length;
    if(!root || strlen(root)>128)return 0;
    length=snprintf(out,256,"%s/%s",root,file);
    return length>0 && length<256;
}
static int load_manifest(const char *root,sd_model models[SD_COUNT])
{
    uint8_t raw[SD_MANIFEST],header[SD_HEADER];
    char path[256];FIL file;UINT got;FRESULT fs;unsigned i,seen=0;
    if(!make_path(path,root,"manifest.bin"))return NPU_SD_MANIFEST;
    if(f_open(&file,path,FA_READ)!=FR_OK)return NPU_SD_FILESYSTEM;
    if(f_size(&file)!=SD_MANIFEST){f_close(&file);return NPU_SD_MANIFEST;}
    fs=f_read(&file,raw,sizeof(raw),&got);f_close(&file);
    if(fs!=FR_OK||got!=sizeof(raw))return NPU_SD_FILESYSTEM;
    memcpy(header,raw,SD_HEADER);memset(header+48,0,4);
    if(memcmp(raw,"NPUSDM1\0",8)||little32(raw+8)!=1||little32(raw+12)!=SD_HEADER||
       little32(raw+16)!=SD_RECORD||little32(raw+20)!=SD_COUNT||little32(raw+24)!=0x40000000u||
       little32(raw+28)!=0x10000000u||little32(raw+32)!=0x10000000u||
       little32(raw+36)!=AI_CAMERA_WORKSPACE_BASE||little32(raw+40)!=AI_CAMERA_WORKSPACE_CAPACITY||
       checksum(raw+SD_HEADER,SD_RECORD*SD_COUNT)!=little32(raw+44)||checksum(header,SD_HEADER)!=little32(raw+48))return NPU_SD_MANIFEST;
    for(i=0;i<SD_COUNT;++i){
        const uint8_t *r=raw+SD_HEADER+i*SD_RECORD;
        const ai_camera_model_desc_t *expected;
        sd_model *m=&models[i];char expected_path[112];uint32_t slot;
        m->id=little32(r);m->base=little32(r+4);m->bytes=little32(r+8);m->crc=little32(r+12);
        m->plan_offset=little32(r+16);m->plan_bytes=little32(r+20);m->workspace_bytes=little32(r+24);
        m->input_offset=little32(r+28);m->input_bytes=little32(r+32);m->output_offset=little32(r+36);
        m->output_bytes=little32(r+40);m->dtype=little32(r+44);m->width=little32(r+48);
        m->height=little32(r+52);m->ops=little32(r+56);m->features=little32(r+60);
        memcpy(m->sha,r+64,32);memcpy(m->name,r+128,80);memcpy(m->file,r+208,112);
        expected=ai_camera_model_find(m->id);
        if(!expected||(seen&(1u<<m->id))||!legal_name(m->name,sizeof(m->name))||
           !memchr(m->file,0,sizeof(m->file))||(m->features&~15u)||((m->features&8u)&&!(m->features&2u))||
           (m->id==1&&(m->features&5u)))return NPU_SD_MANIFEST;
        seen|=1u<<m->id;
        if(snprintf(expected_path,sizeof(expected_path),"models/m%lu/model.bin",(unsigned long)m->id)>=(int)sizeof(expected_path)||
           strcmp(expected_path,m->file))return NPU_SD_MANIFEST;
        slot=m->id==3?0x02000000u:0x01000000u;
        /* Unlike the Linux prepared-tensor path, the existing PS CPU math and
         * catalog are compiled for specific shapes. Reject a mismatched build. */
        if(m->base!=expected->model_base||m->bytes!=expected->image_bytes||m->crc!=expected->image_crc||
           strcmp(m->name,expected->name)||m->plan_offset!=expected->plan_offset||m->plan_bytes!=expected->plan_bytes||
           m->workspace_bytes!=expected->workspace_bytes||m->input_offset!=expected->input_offset||
           m->input_bytes!=expected->input_bytes||m->output_offset!=expected->output_offset||
           m->output_bytes!=expected->output_bytes||m->dtype!=expected->output_dtype||
           m->width!=expected->input_width||m->height!=expected->input_height||
           m->features!=expected->required_features||m->ops!=expected->graph_operations)return NPU_SD_MANIFEST;
        if(!m->bytes||m->bytes>slot||(m->bytes&3)||m->plan_offset<256||m->plan_bytes<256||
           (uint64_t)m->plan_offset+m->plan_bytes!=m->bytes||m->workspace_bytes>0x01000000u||
           (uint64_t)m->input_offset+m->input_bytes>m->workspace_bytes||
           (uint64_t)m->output_offset+m->output_bytes>m->workspace_bytes)return NPU_SD_MANIFEST;
        if(m->features && (read32(G_BASE+0xd0)!=0x4f505431u ||
                          (read32(G_BASE+0xd4)&m->features)!=m->features))return NPU_SD_ABI;
        if(((read32(G_BASE+0xd0)==0x4f505431u?read32(G_BASE+0xd4):0u)&2u)!=(m->features&2u))return NPU_SD_ABI;
    }
    return seen==(AI_CAMERA_MODEL_MASK<<1)?NPU_SD_OK:NPU_SD_MANIFEST;
}
#include "npu_sd_predecoded.h"
static int image_header(FIL *file,const sd_model *m)
{
    static const char names[5][16]={"META","TENSORS","INSTRUCTIONS","ATTRIBUTES","CONSTANTS"};
    uint8_t h[256],p[256],copy[256],directory[320],tensor[128];UINT got;
    uint32_t section_offset[5]={0},section_bytes[5]={0},seen=0,source_bytes;
    unsigned i,j,kind;
    if(f_lseek(file,0)!=FR_OK||f_read(file,h,sizeof(h),&got)!=FR_OK||got!=sizeof(h))return NPU_SD_FILESYSTEM;
    source_bytes=little32(h+32);
    if(memcmp(h,"AIPKG3\0\0",8)||little32(h+8)!=3||little32(h+12)!=256||little32(h+16)!=m->id||
       little32(h+20)!=2||little32(h+24)!=5||little32(h+36)||little32(h+44)||
       !little32(h+40)||(little32(h+40)&4095u)||little32(h+40)>m->workspace_bytes||source_bytes<4096||
       (source_bytes&4095u)||source_bytes!=m->plan_offset||!m->workspace_bytes||(m->workspace_bytes&4095u))return NPU_SD_ABI;
    memcpy(copy,h,sizeof(copy));memset(copy+56,0,4);
    if(checksum(copy,sizeof(copy))!=little32(h+56))return NPU_SD_IMAGE;
    if(f_read(file,directory,sizeof(directory),&got)!=FR_OK||got!=sizeof(directory))return NPU_SD_FILESYSTEM;
    if(checksum(directory,sizeof(directory))!=little32(h+28))return NPU_SD_IMAGE;
    for(i=0;i<5;++i){
        const uint8_t *entry=directory+64*i;
        uint32_t offset=little32(entry+16),bytes=little32(entry+24);
        if(little32(entry+20)||little32(entry+28)||offset<4096||(offset&4095u)||
           little32(entry+36)!=4096||(uint64_t)offset+bytes>source_bytes)return NPU_SD_ABI;
        for(j=40;j<64;++j)if(entry[j])return NPU_SD_ABI;
        for(kind=0;kind<5;++kind)if(!memcmp(entry,names[kind],16))break;
        if(kind==5||(seen&(1u<<kind)))return NPU_SD_ABI;
        for(j=0;j<5;++j)if((seen&(1u<<j))&&
           (uint64_t)offset+bytes>section_offset[j]&&
           (uint64_t)section_offset[j]+section_bytes[j]>offset)return NPU_SD_ABI;
        seen|=1u<<kind;section_offset[kind]=offset;section_bytes[kind]=bytes;
    }
    if(seen!=31||section_bytes[1]%128||!m->ops||
       (uint64_t)m->ops*128u!=section_bytes[2])return NPU_SD_ABI;
    if(f_lseek(file,m->plan_offset)!=FR_OK||f_read(file,p,sizeof(p),&got)!=FR_OK||got!=sizeof(p))return NPU_SD_FILESYSTEM;
    if(memcmp(p,"NPUPLN1\0",8)||little32(p+8)!=1||little32(p+12)!=256||little32(p+16)!=m->id||
       little32(p+20)!=2||little32(p+24)!=512||little32(p+28)!=m->ops||!little32(p+32)||
       little32(p+36)!=4096||(uint64_t)m->ops*8u!=little32(p+40)||
       (little32(p+44)&4095u)||(uint64_t)4096u+little32(p+40)>little32(p+44)||
       (uint64_t)little32(p+32)*512u!=little32(p+48)||
       (uint64_t)little32(p+44)+little32(p+48)>m->plan_bytes||
       little32(p+52)!=m->plan_bytes||(m->plan_bytes&4095u)||
       little32(p+56)!=little32(h+64)||little32(p+60)!=source_bytes||
       little32(p+72)!=section_offset[4]||little32(p+76)!=section_bytes[4]||!section_bytes[4]||
       little32(p+116)!=little32(h+48)||little32(p+120)!=little32(h+52)||
       little32(p+124)!=m->workspace_bytes||little32(p+128)!=m->features||
       (m->id==1&&(m->features&5u)))return NPU_SD_ABI;
    for(i=132;i<256;++i)if(p[i])return NPU_SD_ABI;
    memcpy(copy,p,sizeof(copy));memset(copy+68,0,4);
    if(checksum(copy,sizeof(copy))!=little32(p+68))return NPU_SD_IMAGE;
    for(kind=0;kind<2;++kind){
        uint32_t tid=little32(p+(kind?120:116)),dtype,rank,width;
        uint64_t elements=1;
        if(tid>=section_bytes[1]/128)return NPU_SD_ABI;
        if(f_lseek(file,section_offset[1]+128u*tid)!=FR_OK||
           f_read(file,tensor,sizeof(tensor),&got)!=FR_OK||got!=sizeof(tensor))return NPU_SD_FILESYSTEM;
        dtype=little32(tensor+8);rank=little32(tensor+16);
        if(little32(tensor)!=tid||little32(tensor+4)||little32(tensor+20)||little32(tensor+28)||
           little32(tensor+36)||dtype<1||dtype>4||!rank||rank>8||
           little32(tensor+24)!=(kind?m->output_offset:m->input_offset)||
           little32(tensor+32)!=(kind?m->output_bytes:m->input_bytes))return NPU_SD_ABI;
        width=1u<<(dtype-1u);
        for(i=0;i<rank;++i){
            uint32_t dim=little32(tensor+48+4*i);
            if(!dim||elements>UINT32_MAX/dim)return NPU_SD_ABI;
            elements*=dim;
        }
        if(elements*width!=little32(tensor+32))return NPU_SD_ABI;
        if(kind){if(dtype!=m->dtype)return NPU_SD_ABI;}
        else if(rank!=4||little32(tensor+48)!=1||little32(tensor+52)!=3||
                little32(tensor+56)!=m->height||little32(tensor+60)!=m->width)return NPU_SD_ABI;
    }
    {
        int result=sd_full_control(file,m,h,p,section_offset,section_bytes,directory);
        if(result)return result;
    }
    return f_lseek(file,0)==FR_OK?NPU_SD_OK:NPU_SD_FILESYSTEM;
}
static int file_pass(const char *root,const sd_model *m,int copy_to_ddr)
{
    /* Cold-start, single-owner function: keep the SD chunk out of the small
     * standalone application's stack. No concurrent/reentrant loader calls. */
    static uint8_t buffer[4096];
    char path[256];uint8_t digest[32];uint32_t offset=0,crc=UINT32_MAX;
    npu_sha256 hash;FIL file;UINT got;int result;
    if(!make_path(path,root,m->file))return NPU_SD_MANIFEST;
    if(f_open(&file,path,FA_READ)!=FR_OK)return NPU_SD_FILESYSTEM;
    if(f_size(&file)!=m->bytes){f_close(&file);return NPU_SD_IMAGE;}
    result=image_header(&file,m);
    if(result){f_close(&file);return result;}
    npu_sha256_init(&hash);
    while(offset<m->bytes){
        UINT part=m->bytes-offset;void *destination=buffer;
        if(part>sizeof(buffer))part=sizeof(buffer);
        if(copy_to_ddr)destination=ddr_pointer(m->base+offset);
        if(f_read(&file,destination,part,&got)!=FR_OK||got!=part){f_close(&file);return NPU_SD_FILESYSTEM;}
        fence();crc=npu_crc32_update(crc,destination,part);npu_sha256_update(&hash,destination,part);offset+=part;
    }
    f_close(&file);npu_sha256_final(&hash,digest);
    if((crc^UINT32_MAX)!=m->crc||memcmp(digest,m->sha,32))return NPU_SD_IMAGE;
    return NPU_SD_OK;
}
static int graph_quiet(void)
{
    return !(read32(G_BASE+0x0c)&0x0bu)&&!(read32(G_BASE+4)&0x0bu)&&!read32(G_BASE+0x78);
}
static int wait_mask(uint32_t address,uint32_t mask,uint32_t value)
{
    XTime start,now;XTime_GetTime(&start);
    while((read32(address)&mask)!=value){
        XTime_GetTime(&now);
        if(now-start>(XTime)60*COUNTS_PER_SECOND)return 0;
        usleep(1000);
    }
    return 1;
}
static int quiesce_for_load(void)
{
    /* No task is owned by this cold loader. Refuse any accepted/pending graph
     * task/result or manual lease; do not cancel/release a foreign owner. */
    if(!graph_quiet()||read32(F_BASE+0x40)||(read32(F_BASE+0x8c)&4))return NPU_SD_FOREIGN_OWNER;
    if(read32(F_BASE+0x1c)||read32(F_BASE+0x84))return NPU_SD_DRAIN_TIMEOUT;
    if(read32(F_BASE+4)&16u) {
        /* Live RGB565 slots end at 0x14000000; model slots start there.
         * Graph/PS ownership is already quiet; preview may keep running. */
        write32(G_BASE+8,0);
        return wait_mask(G_BASE+8,0x1f,4) ? NPU_SD_OK : NPU_SD_DRAIN_TIMEOUT;
    }
    write32(F_BASE+4,read32(F_BASE+4)&~5u);
    if(!wait_mask(F_BASE+0x8c,0x87,0))return NPU_SD_DRAIN_TIMEOUT;
    write32(F_BASE+0x90,3);
    if(!wait_mask(F_BASE+0x8c,0x80,0)||(read32(F_BASE+0x8c)&0xff))return NPU_SD_DRAIN_TIMEOUT;
    if(!graph_quiet())return NPU_SD_FOREIGN_OWNER;
    write32(G_BASE+8,0); /* 0 stops PS job admission; no old ARM semantics. */
    if(!wait_mask(G_BASE+8,0x1f,4))return NPU_SD_DRAIN_TIMEOUT;
    return NPU_SD_OK;
}
static int ddr_readback(const sd_model *m)
{
    const uint8_t *data=(const uint8_t *)ddr_pointer(m->base);
    npu_sha256 hash;uint8_t digest[32];uint32_t offset=0,crc=UINT32_MAX;
    fence();npu_sha256_init(&hash);
    while(offset<m->bytes){
        uint32_t part=m->bytes-offset;if(part>4096)part=4096;
        crc=npu_crc32_update(crc,data+offset,part);npu_sha256_update(&hash,data+offset,part);offset+=part;
    }
    npu_sha256_final(&hash,digest);
    return (crc^UINT32_MAX)==m->crc&&!memcmp(digest,m->sha,32)?NPU_SD_OK:NPU_SD_DDR_VERIFY;
}
int npu_sd_preload(const char *root,uint32_t *resident_mask)
{
    sd_model models[SD_COUNT];unsigned i;int result;
    if(!resident_mask)return NPU_SD_MANIFEST;
    *resident_mask=0;
    if(!uncached())return NPU_SD_CACHE_STATE;
    if(read32(F_BASE)!=0x50525031u||read32(F_BASE+0x5c)!=8||read32(F_BASE+0x94)!=0x4c495631u||read32(F_BASE+0x88)!=0x43414d32u||
       read32(G_BASE)!=0x4e475031u||read32(G_BASE+0x88)!=2||
       read32(G_BASE+0xdc)!=(AI_CAMERA_MODEL_MASK<<1))return NPU_SD_ABI;
    result=load_manifest(root,models);if(result)return result;
    /* Two SD passes are deliberate: preflight both before the first write;
     * rehash during copy so changed/truncated media cannot be silently adopted. */
    for(i=0;i<SD_COUNT;++i){result=file_pass(root,&models[i],0);if(result)return result;}
    result=quiesce_for_load();if(result)return result;
    for(i=0;i<SD_COUNT;++i){
        if(!graph_quiet()||(read32(F_BASE+0x8c)&((read32(F_BASE+4)&16u) ? 4u : 0xffu)))return NPU_SD_FOREIGN_OWNER;
        result=file_pass(root,&models[i],1);if(result)return result;
        result=ddr_readback(&models[i]);if(result)return result;
    }
    write32(G_BASE+4,8);
    if(!wait_mask(G_BASE+4,8,0))return NPU_SD_DRAIN_TIMEOUT;
    /* Leave stopped. The existing camera model state machine subsequently
     * performs its normal CRC/configuration/lease-aware selection. */
    *resident_mask=AI_CAMERA_MODEL_MASK;return NPU_SD_OK;
}

int npu_sd_preload_coco80(const char *root,uint32_t *resident_mask)
{
    if(!resident_mask)return NPU_SD_MANIFEST;
    *resident_mask=0;
#if ENABLE_COCO80_CAMERA
    /* Separate optional file: the established two-model manifest/slots stay
     * byte-identical. This function is cold-start only, like the old loader. */
    sd_model m={0};int result;
    static const uint8_t expected_sha[32]={
        0x93,0x7a,0x4c,0x39,0xbc,0xb4,0x59,0x8f,0x36,0xd7,0xa6,0xc2,0x7b,0x1a,0x53,0x22,
        0x2f,0x09,0x6b,0x66,0xc7,0x0b,0x0f,0x3c,0x45,0x82,0xff,0xda,0x77,0x66,0x4b,0xbf};
    const ai_camera_model_desc_t *d=&ai_coco80_model;
    if(!uncached())return NPU_SD_CACHE_STATE;
    if(read32(F_BASE)!=0x50525031u||read32(F_BASE+0x88)!=0x43414d32u||
       read32(G_BASE)!=0x4e475031u||read32(G_BASE+0x88)!=2||
       read32(G_BASE+0xd0)!=0x4f505431u||read32(G_BASE+0xdc)!=(AI_CAMERA_MODEL_MASK<<1)||
       (read32(G_BASE+0xd4)&15u)!=15u)return NPU_SD_ABI;
    m.id=3u;m.base=d->model_base;m.bytes=d->image_bytes;m.crc=d->image_crc;
    m.plan_offset=d->plan_offset;m.plan_bytes=d->plan_bytes;m.workspace_bytes=d->workspace_bytes;
    m.input_offset=d->input_offset;m.input_bytes=d->input_bytes;
    m.output_offset=d->output_offset;m.output_bytes=d->output_bytes;m.dtype=d->output_dtype;
    m.width=d->input_width;m.height=d->input_height;m.ops=d->graph_operations;m.features=d->required_features;
    memcpy(m.sha,expected_sha,sizeof(m.sha));strcpy(m.file,"coco80/model.bin");
    if(m.base!=0x1b000000u||(uint64_t)m.base+m.bytes>0x1c000000u||
       m.workspace_bytes>AI_CAMERA_WORKSPACE_CAPACITY)return NPU_SD_MANIFEST;
    result=file_pass(root,&m,0);if(result)return result;
    result=quiesce_for_load();if(result)return result;
    if(!graph_quiet()||(read32(F_BASE+0x8c)&((read32(F_BASE+4)&16u)?4u:0xffu)))return NPU_SD_FOREIGN_OWNER;
    result=file_pass(root,&m,1);if(result)return result;
    result=ddr_readback(&m);if(result)return result;
    write32(G_BASE+4,8);
    if(!wait_mask(G_BASE+4,8,0))return NPU_SD_DRAIN_TIMEOUT;
    *resident_mask=AI_COCO80_MASK;return NPU_SD_OK;
#else
    (void)root;return NPU_SD_ABI;
#endif
}
