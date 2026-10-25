import { asm } from "./asm.js";

const init = () => asm``;

const instructions = () => asm`
    SUBROUTINE
.logic:

.body_spawn:
    SUBROUTINE
    lda player_x
    and #%111
    bne .end
    lda player_y
    and #%111
    bne .end

    lda #1
    sta temp+1
    lda #0
    sta temp
    lda player_y
    asl ; a(grid_y) = player_y << 1
    rol temp+1
    asl ; grid_y <<= 1
    rol temp+1
    and #%11100000 ; a = (player_y << 2) & 1110_0000
    sta temp       ; grid_i.lo = (player_y << 2) & 1110_0000
    lda player_x
    lsr
    lsr
    lsr
    clc
    adc temp ; grid_i.lo += (player_x >> 3)
             ;               000x_xxxx
    sta temp
    lda player_body_spawn_type
    ldy #0
    sta (temp),y ; TPATM[ grid_i ] = 1

.update_palette:
    sty temp+2
               ; temp    = gfed_cba9 8765_4321
    lsr temp+1 ; temp.hi = 0gfe_dcba -->
    ror temp   ; temp.lo = 9876_5432 -->
    ror temp+2 ; temp+2  = 1000_0000
    lsr temp+1 ; temp.hi = 00gf_edcb -->
    ror temp   ; temp.lo = a987_6543 -->
    ror temp+2 ; temp+2  = 2100_0000
    rol temp+2 ; temp+2  = 1000_0000
    rol temp+2 ; temp+2  = 0000_0002
    rol temp+2 ; temp+2  = 0000_0021
    ldx temp+2
    lda #$08
    sta temp+1 ; temp.hi = 5

    ; temp   = TPALM + (grid_i / 4)
    ; temp+2 = grid_i % 4

.clear_palette:
    ldy #0
    lda (temp),y ; a = TPALM + (grid_i / 4)
    ldx temp+2   ; x = grid_i % 4
    and .slots,x  ; a &= [slots+x]
    sta (temp),y ; [TPALM + (grid_i / 4)] &= [slots+x]

.set_palette:
    ldx temp+2   ; x = grid_i % 4
    lda #BODY_PALETTE
    and .slots_inv,x  ; a &= [slots+x]
    ora (temp),y ; [TPALM + (grid_i / 4)] = new_palette | (prev_palette & slot)
    sta (temp),y

    jmp .end

BODY_PALETTE EQU %01010101

.slots:
    byte %11111100
    byte %11110011
    byte %11001111
    byte %00111111
.slots_inv:
    byte %00000011
    byte %00001100
    byte %00110000
    byte %11000000

    ; shift = (2 * 2bit_i)
    ; slot = 0b11 << shift
    ; new_palette = 1 << shift
    ; temp.* = (temp.* & slot) | new_palette
    ; temp.* = (temp.* & (0b11 << (2 * 2bit_i))) | (1 << (2 * 2bit_i))

    ; pattern_i      = grid_i / 4 ==> grid_i >> 2
    ; pattern_2bit_i = grid_i % 4 ==> grid_i & 0b11
    ; TPALM[ grid_i / 4 ] 

    ; TPALM = x + (32 * 8)

    ; B: 8765_4321
    ; 0: 21
    ; 1: 43
    ; 2: 56
    ; 3: 78

.end:

.check_eat_apple:
    SUBROUTINE
    lda player_x
    cmp apple_x
    bne .end
    lda player_y
    cmp apple_y
    bne .end
    jsr spawn_apple
.end:

.update_pos:
    SUBROUTINE
    clc
    lda player_x
    adc player_v_x
    sta player_x
    clc
    lda player_y
    adc player_v_y
    sta player_y
.end:
`;

const readWriteData = () => asm``;

export { init, instructions, readWriteData };
