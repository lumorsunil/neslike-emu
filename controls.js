import { asm } from "./asm.js";

 // TODO: Set the wanted next direction instead, so that if you press a button and release too early, the snake will still turn at the next grid point

const instructions = () => asm`
controls:
    lda INP1_DOWN
move_player_up:
    tax
    and #BUTTON_UP
    beq move_player_left
    lda player_v_y
    bne move_player_left
    lda player_x
    and #%00000111
    bne move_player_left
    lda #0
    sta player_v_x
    lda #-1
    sta player_v_y
    jmp update_player
move_player_left:
    txa
    and #BUTTON_LEFT
    beq move_player_right
    lda player_v_x
    bne move_player_right
    lda player_y
    and #%00000111
    bne move_player_right
    lda #-1
    sta player_v_x
    lda #0
    sta player_v_y
    jmp update_player
move_player_right:
    txa
    and #BUTTON_RIGHT
    beq move_player_down
    lda player_v_x
    bne move_player_down
    lda player_y
    and #%00000111
    bne move_player_down
    lda #1
    sta player_v_x
    lda #0
    sta player_v_y
    jmp update_player
move_player_down:
    txa
    and #BUTTON_DOWN
    beq update_player
    lda player_v_y
    bne update_player
    lda player_x
    and #%00000111
    bne update_player
    lda #0
    sta player_v_x
    lda #1
    sta player_v_y
update_player:
    clc
    lda player_x
    adc player_v_x
    sta player_x
    clc
    lda player_y
    adc player_v_y
    sta player_y
update_controls_end:
`;

const data = () => asm`
player_v_x: .byte 0
player_v_y: .byte -1
`;

export { instructions, data };
