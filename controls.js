import { asm } from "./asm.js";

const instructions = () => asm`
controls:
    SUBROUTINE

; update_controls_release:
;     lda INP1_RELEASED
;     tax
; release_up:
;     and #BUTTON_UP
;     beq release_left
;     lda #0
;     sta player_wanted_v_y
; release_left:
;     txa
;     and #BUTTON_LEFT
;     beq release_right
;     lda #0
;     sta player_wanted_v_x
; release_right:
;     txa
;     and #BUTTON_RIGHT
;     beq release_down
;     lda #0
;     sta player_wanted_v_x
; release_down:
;     txa
;     and #BUTTON_DOWN
;     beq update_controls_hold
;     lda #0
;     sta player_wanted_v_y


PLAYER_SPEED EQU 2

.update_controls_hold:
    lda INP1_DOWN
.hold_up:
    tax
    and #BUTTON_UP
    beq .hold_down
    lda #-PLAYER_SPEED
    sta player_wanted_v_y
    lda #0
    sta player_wanted_v_x
    jmp .hold_left
.hold_down:
    txa
    and #BUTTON_DOWN
    beq .hold_left
    lda #PLAYER_SPEED
    sta player_wanted_v_y
    lda #0
    sta player_wanted_v_x
.hold_left:
    txa
    and #BUTTON_LEFT
    beq .hold_right
    lda #-PLAYER_SPEED
    sta player_wanted_v_x
    lda #0
    sta player_wanted_v_y
    jmp .update_velocity
.hold_right:
    txa
    and #BUTTON_RIGHT
    beq .update_velocity
    lda #PLAYER_SPEED
    sta player_wanted_v_x
    lda #0
    sta player_wanted_v_y

.update_velocity:
    lda #0
    sta temp+2

.check_wanted_x:
    lda player_y
    and #%111
    bne .check_wanted_y
    lda player_wanted_v_x
    beq .check_wanted_y
    ldx player_v_x
    bne .check_wanted_y
    sta player_v_x
    sta temp+2

.update_player_body_spawn_type_turn_horizontally:
    asl               ; a = player_v_x << 1 ==> carry = sign(player_v_x)
    rol temp          ; temp ´rol´ carry ==> temp[bit0] = carry

    ; update head sprite flip
    lda temp
    sta temp+1
    asl temp+1
    asl temp+1
    lda temp+1
    and #%00000100 ; select horizontal flip
    sta temp+1

    lda player_attr
    and #%11110011 ; turn off vertical flip (and hf)
    ora temp+1
    sta player_attr
    ; end update head sprite flip

    ; update head sprite pattern map
    lda #1
    sta player_pattern
    ; end update head sprite pattern map

    lda player_v_y    ; a = player_v_y
    asl               ; a = player_v_y << 1 ==> carry = sign(player_v_y)
    rol temp          ; temp ´rol´ carry ==> temp[bit1] = temp[bit0]; temp[bit0] = carry
    lda temp          ; a = temp
    and #%011          ; a &= 0b11
    clc
    adc #%100
    sta player_body_spawn_type

    ; TODO: set player_body_spawn_type
    ; 
    ; 00 = left top
    ; 01 = left bottom
    ; 10 = right top 
    ; 11 = right bottom 
    ; if (right and up) bottom_right
    ; if (left and up) bottom_left
    ; if (left and down) top_left
    ; if (right and down) top_right

    stx player_v_y

.check_wanted_y:
    lda player_x
    and #%111
    bne .update_player_body_spawn_type
    lda player_wanted_v_y
    beq .update_player_body_spawn_type
    ldx player_v_y
    bne .update_player_body_spawn_type
    sta player_v_y
    sta temp+2

.update_player_body_spawn_type_turn_vertically:
    asl
    rol temp

    ; update head sprite flip
    lda temp
    sta temp+1
    asl temp+1
    asl temp+1
    lda temp+1
    and #%00001000 ; select vertical flip
    sta temp+1

    lda player_attr
    and #%11110011 ; turn off horizontal flip (and vf)
    ora temp+1
    sta player_attr
    ; end update head sprite flip

    ; update head sprite pattern map
    lda #0
    sta player_pattern
    ; end update head sprite pattern map

    lda player_v_x
    asl
    rol temp
    lda temp
    and #%11 ; 00 = bottom_left, 01 = top_left
    sta player_body_spawn_type

    stx player_v_x

.update_player_body_spawn_type:
    lda temp+2
    bne .end
    ldx #%1000
    lda player_v_y
    bne .set_player_body_spawn_type
    ldx #%1001
.set_player_body_spawn_type:
    stx player_body_spawn_type

.end:
`;

const init = () => asm`
    lda #0
    sta player_v_x
    sta player_wanted_v_x
    sta tail_v_x
    lda #-PLAYER_SPEED
    sta player_v_y
    sta player_wanted_v_y
    sta tail_v_y
`;

const readWriteData = () => asm`
player_v_x: ds 1
player_v_y: ds 1
player_wanted_v_x: ds 1
player_wanted_v_y: ds 1
player_body_spawn_type: ds 1
tail_v_x: ds 1
tail_v_y: ds 1
`;

export { init, instructions, readWriteData };
