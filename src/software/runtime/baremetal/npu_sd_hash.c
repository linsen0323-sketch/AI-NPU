// SPDX-License-Identifier: MIT
#include "npu_sd_hash.h"
#include <string.h>
static uint32_t rotr(uint32_t x, unsigned n) { return (x >> n) | (x << (32-n)); }
static void transform(npu_sha256 *ctx, const uint8_t *data)
{
    static const uint32_t k[64] = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    };
    uint32_t w[64], a,b,c,d,e,f,g,h,t1,t2;
    unsigned i;
    for (i=0;i<16;++i) w[i]=(uint32_t)data[4*i]<<24 | (uint32_t)data[4*i+1]<<16 |
                                  (uint32_t)data[4*i+2]<<8 | data[4*i+3];
    for (i=16;i<64;++i) {
        uint32_t x=w[i-15],y=w[i-2];
        w[i]=w[i-16]+(rotr(x,7)^rotr(x,18)^(x>>3))+w[i-7]+(rotr(y,17)^rotr(y,19)^(y>>10));
    }
    a=ctx->state[0];b=ctx->state[1];c=ctx->state[2];d=ctx->state[3];
    e=ctx->state[4];f=ctx->state[5];g=ctx->state[6];h=ctx->state[7];
    for(i=0;i<64;++i) {
        t1=h+(rotr(e,6)^rotr(e,11)^rotr(e,25))+((e&f)^(~e&g))+k[i]+w[i];
        t2=(rotr(a,2)^rotr(a,13)^rotr(a,22))+((a&b)^(a&c)^(b&c));
        h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
    }
    ctx->state[0]+=a;ctx->state[1]+=b;ctx->state[2]+=c;ctx->state[3]+=d;
    ctx->state[4]+=e;ctx->state[5]+=f;ctx->state[6]+=g;ctx->state[7]+=h;
}
void npu_sha256_init(npu_sha256 *ctx)
{
    static const uint32_t initial[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                                    0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    memcpy(ctx->state,initial,sizeof(initial));ctx->bytes=0;ctx->used=0;
}
void npu_sha256_update(npu_sha256 *ctx,const void *data,size_t bytes)
{
    const uint8_t *p=data;
    ctx->bytes+=bytes;
    while(bytes) {
        size_t part=64-ctx->used;
        if(part>bytes)part=bytes;
        memcpy(ctx->block+ctx->used,p,part);ctx->used+=part;p+=part;bytes-=part;
        if(ctx->used==64){transform(ctx,ctx->block);ctx->used=0;}
    }
}
void npu_sha256_final(npu_sha256 *ctx,uint8_t out[32])
{
    uint64_t bits=ctx->bytes*8;
    uint8_t tail[128]={0x80};
    size_t pad=ctx->used<56?56-ctx->used:120-ctx->used;
    unsigned i;
    for(i=0;i<8;++i)tail[pad+i]=(uint8_t)(bits>>(56-8*i));
    npu_sha256_update(ctx,tail,pad+8);
    for(i=0;i<8;++i){out[4*i]=(uint8_t)(ctx->state[i]>>24);out[4*i+1]=(uint8_t)(ctx->state[i]>>16);
                     out[4*i+2]=(uint8_t)(ctx->state[i]>>8);out[4*i+3]=(uint8_t)ctx->state[i];}
}
uint32_t npu_crc32_update(uint32_t state,const void *data,size_t bytes)
{
    const uint8_t *p=data;
    size_t i;unsigned bit;
    for(i=0;i<bytes;++i){state^=p[i];for(bit=0;bit<8;++bit)state=(state>>1)^((0u-(state&1u))&0xedb88320u);}
    return state;
}
