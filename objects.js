import { asm } from "./asm.js";

const init = () => asm`
player_x EQU SMAP+0
player_y EQU SMAP+1
player_attr EQU SMAP+3

apple_x EQU SMAP+4+0
apple_y EQU SMAP+4+1
apple_attr EQU SMAP+4+3

init_player:
    lda player_attr
    ora #$20 ; enabled | palette = 0
    sta player_attr
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
