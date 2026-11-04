/* SPDX-License-Identifier: MIT
 * Private implementation included only by npu_sd_loader.c, after sd_model and
 * little32/checksum. Full PS-side NPUPRE1/AFF1 validation, never tensor execution.
 * Every access is bounded by the already checked file/model extent. Scratch is
 * cold-loader static storage: this deliberately is not a reentrant interface.
 */
#ifndef NPU_SD_PREDECODED_PRIVATE_H
#define NPU_SD_PREDECODED_PRIVATE_H

static int sd_at(FIL *file,uint32_t offset,void *destination,uint32_t bytes)
{
    UINT got;
    return (uint64_t)offset+bytes<=(uint64_t)f_size(file) &&
           f_lseek(file,offset)==FR_OK && f_read(file,destination,bytes,&got)==FR_OK && got==bytes;
}
static int sd_words(FIL *file,uint32_t offset,uint32_t *words,unsigned count)
{
    uint8_t raw[512];unsigned i;
    if(count>128||!sd_at(file,offset,raw,count*4u))return 0;
    for(i=0;i<count;++i)words[i]=little32(raw+4u*i);
    return 1;
}
static int sd_crc_region(FIL *file,uint32_t offset,uint32_t bytes,uint32_t expected)
{
    static uint8_t chunk[4096];uint32_t accumulator=UINT32_MAX;
    if((uint64_t)offset+bytes>f_size(file)||f_lseek(file,offset)!=FR_OK)return 0;
    while(bytes){UINT got,part=bytes>sizeof(chunk)?sizeof(chunk):bytes;
        if(f_read(file,chunk,part,&got)!=FR_OK||got!=part)return 0;
        accumulator=npu_crc32_update(accumulator,chunk,part);bytes-=part;
    }
    return (accumulator^UINT32_MAX)==expected;
}
static int sd_zero_words(const uint32_t *words,unsigned begin,unsigned end)
{
    unsigned i;for(i=begin;i<end;++i)if(words[i])return 0;return 1;
}
static int sd_pointer(uint32_t pointer,uint64_t bytes,uint64_t span,
                      uint32_t constants_bytes,uint32_t workspace_bytes,int tag)
{
    uint32_t constant=pointer>>31,offset=pointer&UINT32_C(0x7fffffff);
    uint32_t capacity=constant?constants_bytes:workspace_bytes;
    if(tag>=0&&constant!=(uint32_t)tag)return 0;
    /* Bound separate terms before their addition, including malformed input. */
    return bytes>0&&bytes<=capacity&&span<=capacity&&offset<=capacity&&
           (uint64_t)offset+span+bytes<=capacity;
}
static int sd_record(const uint32_t w[128],uint32_t model_id,uint32_t features,
                     uint32_t constants_bytes,uint32_t workspace_bytes)
{
    uint32_t engine=w[0],flags=w[2],opcode=w[3],rank=w[7],lane,axis;
    uint64_t span[3]={0,0,0},inner[3]={1,1,1},iterations=1;
    uint32_t aw,bw,yw;
    if(engine<1||engine>6||rank>8||w[4]<1||w[4]>4||w[5]<1||w[5]>4||w[6]<1||w[6]>4||
       !sd_zero_words(w,56,64)||!sd_zero_words(w,89,91)||!sd_zero_words(w,24+rank,32))return 0;
    switch(engine){
    case 1:if(opcode!=1&&opcode!=4&&opcode!=5&&opcode!=9&&opcode!=10&&opcode!=11)return 0;break;
    case 2:if(model_id!=1||flags!=1||opcode!=20||w[4]!=1||w[6]!=1)return 0;break;
    case 3:return 0;
    case 4:if(opcode<12||opcode>18)return 0;break;
    case 5:if(opcode!=2&&opcode!=3)return 0;break;
    case 6:if(opcode!=19)return 0;break;
    }
    if(model_id==1){
        if(flags!=1||(opcode!=2&&opcode!=3&&opcode!=4&&opcode!=11&&opcode!=19&&opcode!=20))return 0;
    }else if(flags){
        if(flags==8||flags==16||flags==24){
            if(!(features&4u)||engine!=5||opcode!=2||w[6]!=3)return 0;
        }else if(!(features&1u)||(flags!=2&&flags!=6)||engine!=1||opcode!=9||w[4]!=3||
           (flags==6?(w[6]!=1&&w[6]!=2):w[6]!=3))return 0;
    }
    for(axis=0;axis<rank;++axis){
        if(!w[24+axis]||((features&2u)&&w[24+axis]==1)||iterations>UINT32_MAX/w[24+axis])return 0;
        iterations*=w[24+axis];
    }
    for(lane=0;lane<3;++lane){
        if(!sd_zero_words(w,32+lane*8+rank,40+lane*8)||
           ((features&2u)&&!sd_zero_words(w,91+lane*8+rank,99+lane*8)))return 0;
        for(axis=0;axis<rank;++axis){
            uint64_t rewind=(uint64_t)(w[24+axis]-1u)*w[32+lane*8+axis];
            if(rewind>UINT32_MAX||((features&2u)&&rewind!=w[91+lane*8+axis])||span[lane]+rewind>UINT32_MAX)return 0;
            span[lane]+=rewind;
        }
        if((features&2u)&&span[lane]!=w[115+lane])return 0;
    }
    if(features&2u){
        if(w[118]!=UINT32_C(0x31464641)||iterations!=w[119]||!sd_zero_words(w,122,128))return 0;
        if((w[120]||w[121])&&(!(features&8u)||engine!=5||w[120]!=UINT32_C(0x314b5057)))return 0;
    }else if(!sd_zero_words(w,91,128))return 0;
    for(axis=8;axis<=16;++axis)if(!sd_pointer(w[axis],1,0,constants_bytes,workspace_bytes,-1))return 0;
    if(w[10]&UINT32_C(0x80000000))return 0;
    aw=1u<<(w[4]-1u);bw=1u<<(w[5]-1u);yw=1u<<(w[6]-1u);
    if(engine==1||engine==4){
        if(!w[64])return 0;
        inner[0]=(uint64_t)(w[64]-1u)*w[65]+aw;
        inner[2]=(uint64_t)(w[64]-1u)*w[67]+yw;
        if(engine==1&&(opcode==4||opcode==5))inner[1]=(uint64_t)(w[64]-1u)*w[66]+bw;
        if(engine==1&&(opcode==1||(flags&4u))&&
           (!w[17]||w[17]>=UINT32_C(0x80000000)||w[18]||w[19]>62||(w[6]!=1&&w[6]!=2)))return 0;
    }else if(engine==2){
        if(!w[64])return 0;
        inner[0]=(uint64_t)(w[64]-1u)*w[65]+aw;
        inner[2]=yw;
    }else if(engine==5){
        uint32_t ic=w[64],ih=w[65],iw=w[66],oc=w[67],oh=w[68],ow=w[69];
        uint32_t kh=w[70],kw=w[71],sh=w[72],sw=w[73],dh=w[76],dw=w[77],group=w[78];
        uint64_t full_k;
        if(!ic||ic>4096||!oc||oc>4096||!ih||ih>4096||!iw||iw>4096||!oh||oh>4096||!ow||ow>4096||
           !kh||kh>31||!kw||kw>31||!sh||sh>64||!sw||sw>64||!dh||dh>64||!dw||dw>64||
           w[74]>=65536||w[75]>=65536||group!=1||w[79]!=(uint32_t)(opcode==3)||
           w[4]>2||w[6]!=(flags==1?1u:3u)||w[20]!=aw*8u)return 0;
        full_k=(uint64_t)ic*kh*kw;
        if(w[84]!=ic||w[85]!=oc||w[86]!=full_k||
           w[87]!=(uint64_t)ih*iw*aw||w[88]!=(uint64_t)oh*ow*yw||w[83])return 0;
        if(w[120]&&(kh!=3||kw!=3||w[121]!=((ic+7u)/8u)*72u||(w[11]&7u)))return 0;
        if(!sd_pointer(w[11],(uint64_t)oc*(w[120]?w[121]:full_k),0,constants_bytes,workspace_bytes,1))return 0;
        for(axis=0;axis<3;++axis){
            if(w[80+axis]<3||w[80+axis]>4||!sd_pointer(w[12+axis],(uint64_t)oc*(1u<<(w[80+axis]-1u)),
                                                        0,constants_bytes,workspace_bytes,1))return 0;
        }
        if(!sd_pointer(w[17],full_k>1024?(uint64_t)oh*ow*32u*8u:1u,0,constants_bytes,workspace_bytes,0))return 0;
        inner[0]=(uint64_t)ic*ih*iw*aw;inner[2]=(uint64_t)oc*oh*ow*yw;
        if(flags==8||flags==16||flags==24){
            if(iterations!=1||(flags==16?w[21]!=3:
                ((w[21]!=1&&w[21]!=2)||!w[18]||w[18]>=UINT32_C(0x80000000)||w[19]>62))||
               !sd_pointer(w[15],(uint64_t)oc*oh*ow*(1u<<(w[21]-1u)),0,constants_bytes,workspace_bytes,0))return 0;
        }
    }else{
        for(axis=64;axis<72;++axis)if(!w[axis])return 0;
        if(w[4]!=w[6]||w[4]!=(flags==1?1u:3u))return 0;
        /* Bound dimensions before a three-factor product to avoid uint64 wrap. */
        for(axis=64;axis<68;++axis)if(w[axis]>4096)return 0;
        inner[0]=(uint64_t)w[64]*w[65]*aw;inner[2]=(uint64_t)w[66]*w[67]*yw;
    }
    for(lane=0;lane<3;++lane)
        if(!sd_pointer(w[8+lane],inner[lane],span[lane],constants_bytes,workspace_bytes,lane==2?0:-1))return 0;
    return 1;
}
static int sd_tensor(FIL *file,uint32_t tensor_offset,uint32_t tensor_count,uint32_t tid,
                      uint32_t constants_bytes,uint32_t workspace_bytes,uint32_t ops,
                      uint32_t input_id,uint32_t output_id,uint32_t out[32])
{
    unsigned axis;uint64_t elements=1;uint32_t capacity;
    if(tid>=tensor_count||!sd_words(file,tensor_offset+128u*tid,out,32)||out[0]!=tid||out[1]>1||
       out[2]<1||out[2]>4||out[4]>8||out[5]!=out[1]||out[7]||out[9]||out[20]!=64||
       !sd_zero_words(out,21,32)||!sd_zero_words(out,12+out[4],20)||
       out[3]!=(uint32_t)(!out[1]&&out[2]>=3?16:0)||(out[6]&63u)||out[6]>=UINT32_C(0x80000000))return 0;
    for(axis=0;axis<out[4];++axis){
        uint32_t dimension=out[12+axis];
        if(!dimension||elements>UINT32_MAX/dimension)return 0;
        elements*=dimension;
    }
    capacity=out[1]?constants_bytes:workspace_bytes;
    if(elements*(1u<<(out[2]-1u))!=out[8]||(uint64_t)out[6]+out[8]>capacity)return 0;
    if(out[1])return out[10]==UINT32_MAX&&out[11]==UINT32_MAX;
    return (out[10]<ops||(tid==input_id&&out[10]==UINT32_MAX))&&
           (out[11]<ops||(tid==output_id&&out[11]==ops))&&
           (out[10]==UINT32_MAX||out[10]<=out[11]);
}
static int sd_instruction(FIL *file,uint32_t instruction_offset,uint32_t index,
                          uint32_t tensor_offset,uint32_t tensor_count,uint32_t constants_bytes,
                          uint32_t workspace_bytes,uint32_t ops,uint32_t input_id,uint32_t output_id,
                          uint32_t attributes_offset,uint32_t attributes_bytes,uint32_t ins[32])
{
    uint32_t i,tensor[32],cursor,end,previous=0;
    if(!sd_words(file,instruction_offset+128u*index,ins,32)||ins[0]<1||ins[0]>20||
       ins[0]==6||ins[0]==7||ins[0]==8||ins[1]||
       ins[2]<1||ins[2]>4||ins[3]<1||ins[3]>4||!sd_zero_words(ins,15,32)||
       (ins[12]&15u)||(uint64_t)ins[12]+ins[13]>attributes_bytes)return 0;
    for(i=4;i<12;++i){
        int used=i<8?i<4+ins[2]:i<8+ins[3];
        if(!used){if(ins[i]!=UINT32_MAX)return 0;continue;}
        if(!sd_tensor(file,tensor_offset,tensor_count,ins[i],constants_bytes,workspace_bytes,
                      ops,input_id,output_id,tensor)||(i>=8&&tensor[1]))return 0;
    }
    cursor=ins[12];end=cursor+ins[13];
    while(cursor<end){
        uint8_t raw[16];uint32_t field,kind,count,value,high;
        if((uint64_t)cursor+16u>end||!sd_at(file,attributes_offset+cursor,raw,16))return 0;
        field=little32(raw);kind=(uint32_t)raw[4]|(uint32_t)raw[5]<<8;
        count=(uint32_t)raw[6]|(uint32_t)raw[7]<<8;value=little32(raw+8);high=little32(raw+12);
        if(field<=previous||field>22||kind<1||kind>3)return 0;
        if(kind==3){
            if(high||(value&7u)||count>8||(uint64_t)value+count*8u>(uint64_t)ins[12]+ins[13])return 0;
            if(value<end)end=value;
            if((uint64_t)cursor+16u>end)return 0;
        }else{
            if(count!=1)return 0;
            if(kind==2&&(high||!sd_tensor(file,tensor_offset,tensor_count,value,constants_bytes,workspace_bytes,
                                          ops,input_id,output_id,tensor)||!tensor[1]))return 0;
        }
        previous=field;cursor+=16u;
    }
    return cursor==end;
}
static int sd_full_control(FIL *file,const sd_model *m,const uint8_t package[256],
                            const uint8_t plan[256],const uint32_t offset[5],const uint32_t bytes[5],
                            const uint8_t directory[320])
{
    uint32_t h[64],p[64],q[32],copy[32],w[128],ins[32],tensor[32],index[2],next[32];
    uint32_t i,j,cursor=0,absorb_until=0,tensor_count=bytes[1]/128u,previous_end=4096;
    for(i=0;i<64;++i){h[i]=little32(package+4*i);p[i]=little32(plan+4*i);}
    if(h[15]||!sd_zero_words(h,18,64))return NPU_SD_ABI;
    if(m->features&2u){
        if(!sd_words(file,0x400u,q,32))return NPU_SD_ABI;
        memcpy(copy,q,sizeof(copy));copy[31]=0;
        if(q[0]!=UINT32_C(0x5055504e)||q[1]!=UINT32_C(0x00314552)||q[2]!=1||q[3]!=128||
           q[4]!=m->id||q[5]!=2||q[6]!=h[8]||q[7]!=p[31]||q[8]!=h[12]||q[9]!=h[13]||
           q[10]!=h[17]||q[11]!=m->ops||!sd_zero_words(q,22,31)||checksum(copy,sizeof(copy))!=q[31])return NPU_SD_ABI;
    }
    for(i=0;i<5;++i){
        uint32_t expected_crc=0;
        if(!bytes[i]||offset[i]<previous_end||
           ((m->features&2u)&&(q[12+2*i]!=offset[i]||q[13+2*i]!=bytes[i])))return NPU_SD_ABI;
        previous_end=offset[i]+bytes[i];
        for(j=0;j<5;++j)if(little32(directory+64*j+16)==offset[i])expected_crc=little32(directory+64*j+32);
        if(!sd_crc_region(file,offset[i],bytes[i],expected_crc))return NPU_SD_IMAGE;
    }
    if(!sd_crc_region(file,256,h[8]-256,h[16])||
       !sd_crc_region(file,m->plan_offset+256,m->plan_bytes-256,p[16]))return NPU_SD_IMAGE;
    for(i=0;i<tensor_count;++i)
        if(!sd_tensor(file,offset[1],tensor_count,i,bytes[4],h[10],m->ops,h[12],h[13],tensor))return NPU_SD_ABI;
    if(h[12]>=tensor_count||h[13]>=tensor_count||
       !sd_tensor(file,offset[1],tensor_count,h[12],bytes[4],h[10],m->ops,h[12],h[13],tensor)||tensor[1]||
       !sd_tensor(file,offset[1],tensor_count,h[13],bytes[4],h[10],m->ops,h[12],h[13],tensor)||tensor[1])return NPU_SD_ABI;
    if(h[17]!=UINT32_MAX&&(!sd_tensor(file,offset[1],tensor_count,h[17],bytes[4],h[10],m->ops,h[12],h[13],tensor)||!tensor[1]))return NPU_SD_ABI;
    for(i=20;i<=26;i+=3){
        uint32_t width;
        if(p[i+2]<3||p[i+2]>4||p[i+1]<2)return NPU_SD_ABI;
        width=1u<<(p[i+2]-1u);
        if(p[i]%width||(uint64_t)p[i]+(uint64_t)p[i+1]*width>bytes[4])return NPU_SD_ABI;
    }
    for(i=0;i<m->ops;++i){
        uint32_t record;
        if(!sd_instruction(file,offset[2],i,offset[1],tensor_count,bytes[4],h[10],m->ops,h[12],h[13],
                            offset[3],bytes[3],ins)||
           (ins[0]==20&&m->id!=1)||
           !sd_words(file,m->plan_offset+p[9]+8*i,index,2)||index[0]!=cursor||
           (uint64_t)index[0]+index[1]>p[8])return NPU_SD_ABI;
        if(!index[1]){if(!(m->features&5u)||i>absorb_until||!i)return NPU_SD_ABI;}
        else if(i<=absorb_until&&i)return NPU_SD_ABI;
        for(record=0;record<index[1];++record){
            if(!sd_words(file,m->plan_offset+p[11]+512u*(index[0]+record),w,128)||w[1]!=i||w[3]!=ins[0]||
               !sd_record(w,m->id,m->features,bytes[4],p[31]))return NPU_SD_ABI;
            if(w[2]==8||w[2]==16||w[2]==24){
                uint32_t count=w[2]==8?1u:w[2]==24?3u:2u,previous=ins[8];
                if(i+count>=m->ops||ins[3]!=1)return NPU_SD_ABI;
                if(w[2]&16u){uint32_t sigmoid;
                    if(!sd_words(file,offset[2]+128u*(i+1u),next,32)||next[0]!=9||next[2]!=1||next[3]!=1||next[4]!=previous)return NPU_SD_ABI;
                    sigmoid=next[8];
                    if(!sd_words(file,offset[2]+128u*(i+2u),next,32)||next[0]!=5||next[2]!=2||next[3]!=1||
                       !((next[4]==previous&&next[5]==sigmoid)||(next[5]==previous&&next[4]==sigmoid)))return NPU_SD_ABI;
                    previous=next[8];
                }
                if(w[2]&8u){
                    if(!sd_words(file,offset[2]+128u*(i+count),next,32)||next[0]!=1||next[2]!=1||next[3]!=1||next[4]!=previous)return NPU_SD_ABI;
                }
                absorb_until=i+count;
            }
            if(w[2]==2||w[2]==6){
                uint32_t count=w[2]==6?2u:1u;
                if(i+count>=m->ops||ins[2]!=1||ins[3]!=1||
                   !sd_words(file,offset[2]+128u*(i+1u),next,32)||next[0]!=5||next[2]!=2||next[3]!=1||
                   !((next[4]==ins[4]&&next[5]==ins[8])||(next[5]==ins[4]&&next[4]==ins[8])))return NPU_SD_ABI;
                if(count==2){uint32_t mul_output=next[8];
                    if(!sd_words(file,offset[2]+128u*(i+2u),next,32)||next[0]!=1||next[2]!=1||next[3]!=1||next[4]!=mul_output)return NPU_SD_ABI;
                }
                absorb_until=i+count;
            }
        }
        cursor+=index[1];
    }
    return cursor==p[8]?NPU_SD_OK:NPU_SD_ABI;
}
#endif
