#ifndef AI_BOARD_KEYS_H
#define AI_BOARD_KEYS_H
#include <stdint.h>
/* Navigator V3.9 active-low keys, in the existing source pin order:
 * KEY0 PS MIO12 -> ResNet1; KEY1 PS MIO11 -> NEU3;
 * KEY2 PL L14 -> COCO4; KEY3 PL K16 -> start/stop.
 * A held key emits one press only; simultaneous model keys choose KEY0 first.
 */
enum { AI_BOARD_KEY_RESNET=1u, AI_BOARD_KEY_NEU=2u,
       AI_BOARD_KEY_COCO=4u, AI_BOARD_KEY_RUN=8u };
int ai_board_keys_init(uint64_t now_ms);
uint32_t ai_board_keys_poll(uint64_t now_ms);
#endif
