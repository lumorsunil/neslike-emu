import { asm } from "./asm.js";
import * as constants from "./constants.js";

//             ->
//       -TTTTTO 
//
//       Head spawns body parts, tail eats them
//
//       How does the tail know where to go?
//       A: It has it's own velocity, it turns whenever it encounters a curved body part
//
//
//  |----------------------|
//  |                      |
//  |            o         |
//  |            |         |
//  |            |         |
//  |   o-->     v         |
//  |                      |
//  |        o-\           |
//  |          |           |
//  |          v           |
//  |----------------------|

const init = () => asm`
player_x EQU SMAP+8+0
player_y EQU SMAP+8+1
player_pattern EQU SMAP+8+2
player_attr EQU SMAP+8+3
PLAYER_BODY_SIZE_INIT = ${constants.PLAYER_BODY_SIZE_INIT}

tail_x EQU SMAP+16+0
tail_y EQU SMAP+16+1
tail_pattern EQU SMAP+16+2
tail_attr EQU SMAP+16+3

under_tail_x EQU SMAP+12+0
under_tail_y EQU SMAP+12+1
under_tail_pattern EQU SMAP+12+2
under_tail_attr EQU SMAP+12+3

under_head_x EQU SMAP+4+0
under_head_y EQU SMAP+4+1
under_head_pattern EQU SMAP+4+2
under_head_attr EQU SMAP+4+3

apple_x EQU SMAP+0
apple_y EQU SMAP+1
apple_pattern EQU SMAP+2
apple_attr EQU SMAP+3

init_player:
    lda player_attr
    ora #$20 ; enabled | palette = 0
    sta player_attr
    lda tail_attr
    ora #$20 ; enabled | palette = 0
    sta tail_attr
    lda under_tail_attr
    lda under_head_attr
    ora #$22 ; enabled | palette = 0
    sta under_tail_attr
    sta under_head_attr
    lda #4
    sta under_tail_pattern
    sta under_head_pattern
init_apple_data:
    lda apple_attr
    ora #$21 ; enabled | palette = 1
    sta apple_attr
    jsr spawn_apple
`;

const subroutines = () => asm`
spawn_apple:
    lda RAND
    and #%11111000
    sta apple_x
    lda RAND
    and #%11111000
    sta apple_y
    rts
`;

export { init, subroutines };
