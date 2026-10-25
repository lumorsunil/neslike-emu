import { asm } from "./asm.js";

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
player_x EQU SMAP+4+0
player_y EQU SMAP+4+1
player_attr EQU SMAP+4+3

tail_x EQU SMAP+8+0
tail_y EQU SMAP+8+1
tail_attr EQU SMAP+8+3

apple_x EQU SMAP+0
apple_y EQU SMAP+1
apple_attr EQU SMAP+3

init_player:
    lda player_attr
    ora #$20 ; enabled | palette = 0
    sta player_attr
    lda tail_attr
    ora #$20 ; enabled | palette = 0
    sta tail_attr
    lda #20
    sta tail_x
    sta tail_y
init_apply_data:
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
