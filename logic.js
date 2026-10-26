import { asm } from "./asm.js";
import * as constants from "./constants.js";

const tilePatternIndexOf = (x, y) => {
    const i = (x + y * 32) + constants.TPATM;
    const lo = i & 0x00FF;
    const hi = (i & 0xFF00) >> 8;

    return { lo, hi };
};

const tilePaletteIndexOf = (x, y) => {
    const i = (x / 4 + y * 8) + constants.TPALM;
    const lo = i & 0x00FF;
    const hi = (i & 0xFF00) >> 8;

    const bit_i = (x % 4);
    const shift = bit_i * 2;
    const slot_clear = 0b11111111 ^ (0b11 << shift);

    return { lo, hi, shift, slot_clear };
};

const setTilePattern = (x, y, pattern) => {
    const tilePatternIndex = tilePatternIndexOf(x, y);

    return asm`
    lda #${tilePatternIndex.lo}
    sta temp
    lda #${tilePatternIndex.hi}
    sta temp+1
    lda #${pattern}
    ldy #0
    sta (temp),y
`;
};

const setTilePalette = (x, y, palette) => {
    const tilePaletteIndex = tilePaletteIndexOf(x, y);

    return asm`
    lda #${tilePaletteIndex.lo}
    sta temp
    lda #${tilePaletteIndex.hi}
    sta temp+1
    ldy #0
    lda (temp),y
    and #${tilePaletteIndex.slot_clear}
    ora #${palette << tilePaletteIndex.shift}
    sta (temp),y
`;
};

const initPlayerBody = () => [...new Array(constants.PLAYER_BODY_SIZE_INIT)].map((_, i) => {
    const x = 16;
    const y = 32 - 5 - constants.PLAYER_BODY_SIZE_INIT + 1 + i;

    return `
${setTilePattern(x, y, 5)}
${setTilePalette(x, y, 1)}
`;
}).join('');

const init = () => asm`
    lda #(32 - (5 + PLAYER_BODY_SIZE_INIT)) << 3
    sta player_y
    sta under_head_y
    lda #(32 / 2) << 3
    sta player_x
    sta under_head_x

${initPlayerBody()}

    lda #(32 - 5 + 1) << 3
    sta tail_y
    sta under_tail_y
    lda #(32 / 2) << 3
    sta tail_x
    sta under_tail_x
    lda #2
    sta tail_pattern
`;

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
    ldx player_body_spawn_type
    lda body_type,x
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
    and palette_slots,x  ; a &= [slots+x]
    sta (temp),y ; [TPALM + (grid_i / 4)] &= [slots+x]

.set_palette:
    ldx temp+2   ; x = grid_i % 4
    lda #BODY_PALETTE
    and palette_slots_inv,x  ; a &= [slots+x]
    ora (temp),y ; [TPALM + (grid_i / 4)] = new_palette | (prev_palette & slot)
    sta (temp),y

BODY_PALETTE EQU %01010101

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

.tail_eat_body:
    SUBROUTINE

    lda tail_x
    and #%111
    bne .escape
    lda tail_y
    and #%111
    bne .escape

    jmp .skip_escape
.escape:
    jmp .end
.skip_escape:

.calculate_grid_i:
    lda #1
    sta temp+1
    lda #0
    sta temp
    lda tail_y
    asl ; a(grid_y) = player_y << 1
    rol temp+1
    asl ; grid_y <<= 1
    rol temp+1
    and #%11100000 ; a = (player_y << 2) & 1110_0000
    sta temp       ; grid_i.lo = (player_y << 2) & 1110_0000
    lda tail_x
    lsr
    lsr
    lsr
    clc
    adc temp ; grid_i.lo += (player_x >> 3)
    sta temp
    lda (temp),y ; x = TPATM[ grid_i ]
    tax
    lda #0
    ldy #0
    sta (temp),y ; TPATM[ grid_i ] = 1

.handle_tail_turn:
    lda is_body_pattern_straight,x
    bne .end

    lda tail_v_x
    beq .handle_tail_turn_horizontal

.handle_tail_turn_vertical:
    ; tail_pattern = vertical tail
    lda #2
    sta tail_pattern
    ; tail_flip_x = 0
    lda tail_attr
    and #%11110011
    ; tail_flip_y = body_pattern_to_flip_y[x]
    ora body_pattern_to_flip_y,x
    sta tail_attr
    ; tail_v_x = 0
    lda #0
    sta tail_v_x
    ; tail_v_y = body_pattern_to_v_y[x]
    lda body_pattern_to_v_y,x
    sta tail_v_y
    jmp .handle_tail_turn_end

.handle_tail_turn_horizontal:
    ; tail_pattern = horizontal tail
    lda #3
    sta tail_pattern
    ; tail_flip_y = 0
    lda tail_attr
    and #%11110011
    ; tail_flip_x = body_pattern_to_flip_x[x]
    ora body_pattern_to_flip_x,x
    sta tail_attr
    ; tail_v_y = 0
    lda #0
    sta tail_v_y
    ; tail_v_x = body_pattern_to_v_x[x]
    lda body_pattern_to_v_x,x
    sta tail_v_x

.handle_tail_turn_end:

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

.clear_palette:
    ldy #0
    lda (temp),y ; a = TPALM + (grid_i / 4)
    ldx temp+2   ; x = grid_i % 4
    and palette_slots,x  ; a &= [slots+x]
    sta (temp),y ; [TPALM + (grid_i / 4)] &= [slots+x]

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

.update_head_pos:
    SUBROUTINE
    clc
    lda player_x
    adc player_v_x
    sta player_x
    sta under_head_x
    clc
    lda player_y
    adc player_v_y
    sta player_y
    sta under_head_y
.end:

.update_tail_pos:
    SUBROUTINE
    clc
    lda tail_x
    adc tail_v_x
    sta tail_x
    sta under_tail_x
    clc
    lda tail_y
    adc tail_v_y
    sta tail_y
    sta under_tail_y
.end:
`;

const readWriteData = () => asm``;

// top_left     = 00
// bottom_left  = 01
// top_right    = 10
// bottom_right = 11

const readOnlyData = () => asm`
body_type:
.horizontal_to_vertical:
    ; %ab
    ;  a = y
    ;  b = x
    ; byte %01, %00, %11, %10
    byte %010, %100, %001, %011
.vertical_to_horizontal:
    ; %ab
    ;  a = x
    ;  b = y
    ; byte %01, %00, %11, %10
    ; byte %10, %11, %00, %01
    byte %011, %100, %001, %010
.straight:
    byte 5, 6

palette_slots:
    byte %11111100
    byte %11110011
    byte %11001111
    byte %00111111
palette_slots_inv:
    byte %00000011
    byte %00001100
    byte %00110000
    byte %11000000

body_pattern_to_flip_y:
    byte 0, %0, %1000, %0, %1000
body_pattern_to_v_y:
    byte 0, -PLAYER_SPEED, PLAYER_SPEED, -PLAYER_SPEED, PLAYER_SPEED

body_pattern_to_flip_x:
    byte 0, %0, %0, %100, %100
body_pattern_to_v_x:
    byte 0, -PLAYER_SPEED, -PLAYER_SPEED, PLAYER_SPEED, PLAYER_SPEED

is_body_pattern_straight:
    byte 1, 0, 0, 0, 0, 1, 1
`;

export { init, instructions, readWriteData, readOnlyData };
