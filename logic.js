import { asm } from "./asm.js";
import * as constants from "./constants.js";
import * as controls from "./controls.js";
import * as logic from "./logic.js";
import * as graphics from "./graphics.js";

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

; init growing
    lda #0
    sta growing
; init is_game_over
    lda #0
    sta is_game_over
`;

const instructions = () => asm`
    SUBROUTINE
.logic:

.body_spawn:
    SUBROUTINE

    jmp .body_spawn_start
.escape:
    jmp .end

.body_spawn_start:
    lda player_x
    and #%111
    bne .escape
    lda player_y
    and #%111
    bne .escape

; head has reached grid intersection

; handle growing
    lda growing
    beq .spawn_body_part
    dec growing

.spawn_body_part:
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

.check_death:
    lda temp
    sta temp2
    lda temp+1
    sta temp2+1

.check_death_v_x_pos:
    ; if (player_v_x > 0) check (temp + 1) % 32
    lda player_v_x
    beq .check_death_v_y_pos
    bmi .check_death_v_x_neg
    lda temp2
    clc
    adc #1
    and #%00011111
    tax
    lda temp2
    and #%11100000
    sta temp2
    txa
    clc
    adc temp2
    sta temp2
    jmp .check_death_tile

.check_death_v_x_neg:
    ; else if (player_v_x < 0) check temp - 1
    ; true
    lda temp2
    sec
    sbc #1
    and #%00011111
    tax
    lda temp2
    and #%11100000
    sta temp2
    txa
    clc
    adc temp2
    sta temp2
    jmp .check_death_tile

.check_death_v_y_pos:
    ; else if (player_v_y > 0) check (temp + 32) % 0x3ff

    ; x = 0b0000_0000_0001_1111
    ; y = 0b0000_0011_1110_0000

    ; y+1 = 0b0000_0000_001a_bcde
    ; 0b0000_0001_000a_bcde

    lda player_v_y
    bmi .check_death_v_y_neg
    lda temp2
    clc
    adc #32
    sta temp2
    lda #0
    adc temp2+1 ; temp2.hi += carry
    and #%11    ; temp2.hi %= 0b11
    clc
    adc #(TPATM >> 8)
    sta temp2+1

    jmp .check_death_tile

.check_death_v_y_neg:
    ; else if (player_v_y < 0) check temp - 32
    ; true
    lda temp2 ; 0b0000_00yy_yyyx_xxxx
    sec
    sbc #32
    sta temp2
    lda temp2+1
    sbc #0
    and #%11
    clc
    adc #(TPATM >> 8)
    sta temp2+1

.check_death_tile:
    ldy #0
    lda (temp2),y
    beq .check_death_end
    ; GAME OVER
    lda #1
    sta is_game_over
    jmp game_over

    ; 0,0 - 1,0 = 31,0
    ; 0,0 - 0,1 = 0,31
    ;
    ; x = +-1
    ; y = +-32
    ;
    ; 0,0 = 0x0000
    ; 1,0 = 0x0001
    ; 0,1 = 0x0020
    ; 0,2 = 0x0040
    ;
    ; i: 0 - 1 ==> 0x0000 - 1 = 0xFFFF ==> 0x03FF = (0xFFFF & 0b0000_0011_1111_1111)
    ; i: 0 - 32 ==> 0x0000 - 32 = 0xFFE0 ==> 0x03FF = (0xFFFF & 0b0000_0011_1111_1111)
    ;
    ; i: 0x3FF + 1 ==> 0x0400 ==> 0x0000 = (0x0400 & 0b0000_0011_1111_1111)
    ; i: 0x3FF + 32 ==> 0x041f ==> 0x001f = (0x041f & 0b0000_0011_1111_1111)
    ;
    ; column - 1 = (idx & 0xfe0) + ((idx + 31) & 0x1f)

.check_death_end:

.update_palette:
    ldy #0
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
    bne .handle_tail_turn_end

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
; apple eaten
    jsr spawn_apple
    lda growing
    adc #PLAYER_GROWTH_PER_APPLE
    sta growing
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
    lda growing
    bne .end
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

const readWriteData = () => asm`
growing: ds 1
is_game_over: ds 1
`;

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

const displayGameOver = () => {
    const gameOver = constants.STRING("GAME OVER");
    const y = 16;

    return gameOver.map((c, i) => asm`
    lda #${c}
    sta ${constants.TPATM + (i + 10 + y * 32)}
    `).join('');
};

const subroutines = () => asm`
game_over:
    SUBROUTINE
${displayGameOver()}
.input_check:
    lda INP1_PRESSED
    and #BUTTON_A
    bne .restart
    jmp .input_check
.restart:
    jsr restart
    jmp frame

restart:
    SUBROUTINE
${controls.init()}
${logic.init()}

    lda tail_attr
    and #%11110011
    sta tail_attr
    lda #2
    sta tail_pattern
    lda player_attr
    and #%11110011
    sta player_attr
    lda #0
    sta player_pattern

    jsr init_board
    jsr spawn_apple
    rts
`;

export { init, instructions, readWriteData, readOnlyData, subroutines };
