#ifndef AIPKG3_ABI_H
#define AIPKG3_ABI_H
#include <stdint.h>

/* All fields and tensor payloads are little endian. No native pointer is
 * serialized. Package and workspace bases are supplied at load time. */
#pragma pack(push, 1)
typedef struct {
    uint8_t magic[8];              /* "AIPKG3\0\0" */
    uint32_t version, header_bytes, model_id, engine_profile;
    uint32_t section_count, directory_crc32;
    uint64_t image_bytes, workspace_bytes;
    uint32_t input_tensor_id, output_tensor_id, header_crc32, flags;
    uint32_t body_crc32;
    uint32_t input_lut_tensor_id;  /* optional U8->Q16 LUT, else 0xFFFFFFFF */
    uint8_t reserved[184];
} aipkg3_header;

typedef struct {
    uint8_t name[16];
    uint64_t file_offset, bytes;
    uint32_t crc32, alignment;
    uint8_t reserved[24];
} aipkg3_section;

typedef struct { uint32_t words[32]; } aipkg3_tensor;
typedef struct { uint32_t words[32]; } aipkg3_instruction;

typedef struct {
    uint32_t field_id;
    uint16_t kind, count;          /* 1=signed scalar, 2=tensor ID, 3=I64 vector */
    int64_t payload;              /* scalar/ID or offset within ATTRIBUTES */
} aipkg3_attribute;
#pragma pack(pop)

enum aipkg3_profile { AIPKG3_R18_ABI1 = 1, AIPKG3_INTEGER_GRAPH = 2 };
enum aipkg3_dtype { AIPKG3_I8=1, AIPKG3_I16=2, AIPKG3_I32=3, AIPKG3_I64=4 };
enum aipkg3_opcode {
    AI_QUANT=1, AI_CONV=2, AI_LINEAR=3, AI_ADD=4, AI_MUL=5,
    AI_MATMUL=6, AI_LAYERNORM=7, AI_SOFTMAX=8, AI_SIGMOID=9,
    AI_EXP=10, AI_RELU=11, AI_RESHAPE=12, AI_TRANSPOSE=13,
    AI_CONCAT=14, AI_SLICE=15, AI_SPLIT=16, AI_EXPAND=17,
    AI_RESIZE_NEAREST=18, AI_MAXPOOL=19, AI_GAP=20
};
enum aipkg3_field {
    AI_F_MULTIPLIER=1, AI_F_SHIFT=2, AI_F_BITS=3, AI_F_WEIGHT=4,
    AI_F_BIAS=5, AI_F_ACTIVATION_BITS=6, AI_F_STRIDES=7, AI_F_PADS=8,
    AI_F_DILATIONS=9, AI_F_GROUP=10, AI_F_GAMMA=11, AI_F_BETA=12,
    AI_F_EPSILON_Q48=13, AI_F_AXIS=14, AI_F_SHAPE=15, AI_F_PERM=16,
    AI_F_STARTS=17, AI_F_ENDS=18, AI_F_AXES=19, AI_F_STEPS=20,
    AI_F_SIZES=21, AI_F_KERNEL=22
};

#if defined(__cplusplus)
static_assert(sizeof(aipkg3_header)==256, "header ABI");
static_assert(sizeof(aipkg3_section)==64, "directory ABI");
static_assert(sizeof(aipkg3_instruction)==128, "instruction ABI");
static_assert(sizeof(aipkg3_tensor)==128, "tensor ABI");
static_assert(sizeof(aipkg3_attribute)==16, "attribute ABI");
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(aipkg3_header)==256, "header ABI");
_Static_assert(sizeof(aipkg3_section)==64, "directory ABI");
_Static_assert(sizeof(aipkg3_attribute)==16, "attribute ABI");
#endif
#endif
