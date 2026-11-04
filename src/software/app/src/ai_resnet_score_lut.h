#ifndef AI_RESNET_SCORE_LUT_H
#define AI_RESNET_SCORE_LUT_H
#include <stdint.h>
/* Display-only softmax of six signed INT8 logits. Frozen final output
 * scale=0.1327972710132599, common zero_point=0. Q24 exp(-delta*scale)
 * for delta0..255, rounded half up; max subtraction is exact in INT32.
 * Provenance: verification/linux_final_20261101/resnet_score_provenance.json.
 * Does not change argmax, graph execution or model package bytes. */
#define AI_RESNET_SCORE_CLASSES 6u
#define AI_RESNET_SCORE_ONE_Q24 UINT32_C(16777216)
static const uint32_t ai_resnet_exp_neg_q24[256] = {
    16777216u, 14690845u, 12863930u, 11264205u, 9863417u, 8636828u, 7562775u, 6622288u,
    5798757u, 5077639u, 4446197u, 3893279u, 3409121u, 2985172u, 2613943u, 2288880u,
    2004241u, 1754999u, 1536752u, 1345645u, 1178304u, 1031773u, 903465u, 791112u,
    692732u, 606585u, 531152u, 465099u, 407261u, 356615u, 312267u, 273434u,
    239431u, 209656u, 183584u, 160754u, 140763u, 123258u, 107930u, 94508u,
    82755u, 72464u, 63453u, 55562u, 48652u, 42602u, 37304u, 32665u,
    28603u, 25046u, 21931u, 19204u, 16816u, 14725u, 12894u, 11290u,
    9886u, 8657u, 7580u, 6638u, 5812u, 5089u, 4456u, 3902u,
    3417u, 2992u, 2620u, 2294u, 2009u, 1759u, 1540u, 1349u,
    1181u, 1034u, 906u, 793u, 694u, 608u, 532u, 466u,
    408u, 357u, 313u, 274u, 240u, 210u, 184u, 161u,
    141u, 124u, 108u, 95u, 83u, 73u, 64u, 56u,
    49u, 43u, 37u, 33u, 29u, 25u, 22u, 19u,
    17u, 15u, 13u, 11u, 10u, 9u, 8u, 7u,
    6u, 5u, 4u, 4u, 3u, 3u, 3u, 2u,
    2u, 2u, 2u, 1u, 1u, 1u, 1u, 1u,
    1u, 1u, 1u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
    0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u,
};
#endif
