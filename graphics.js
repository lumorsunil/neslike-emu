import { asm } from "./asm.js";
import { tile } from "./utils.js";
import { font } from "./font.js";
import { FONT } from "./constants.js";

const init = () => asm`
init_graphics:
    SUBROUTINE

.set_tile_data_pointer:
    lda #<tile_data
    sta $2a20
    lda #>tile_data
    sta $2a21

.set_sprite_data_pointer:
    lda #<sprite_data
    sta $2a22
    lda #>sprite_data
    sta $2a23

.init_tile_palette_data:
    ldx #tile_palette_data_size-1
.tile_palette_data_store:
    lda tile_palette_data,x
    sta TPAL,x
    dex
    bpl .tile_palette_data_store

.init_sprite_palette_data:
    ldx #sprite_palette_data_size-1
.sprite_palette_data_store:
    lda sprite_palette_data,x
    sta SPAL,x
    dex
    bpl .sprite_palette_data_store

    jsr init_board

.init_sprites:
    lda #0
    ldx #$FF
.init_sprites_loop:
    sta SMAP,x
    dex
    bne .init_sprites_loop
    sta SMAP,x
`;

const readOnlyData = () => asm`
tile_data:    
    byte 0, 0, 0, 1, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 1, 0
; top_left
${tile(`
11122110
21221110
22122110
12212130
11222100
11111300
11133000
33300000
`)}
; bottom_left
${tile(`
00000000
22100000
12211000
11221100
11221100
12211110
11221110
11122110
`)}
; top_right
${tile(`
31122111
31112212
31122122
03121221
03122211
00311111
00033111
00000333
`)}
; bottom_right
${tile(`
00000002
00003122
00311221
03112211
03112211
31111221
31112211
31122111
`)}
; vertical
${tile(`
31221110
31122110
03112211
00311221
00311221
03112211
31122113
31221110
`)}
; horizontal
${tile(`
11000011
21111112
22111122
12211221
11222211
11122111
33111133
00333300
`)}
${font()}
tile_data_size = . - tile_data

tile_palette_data:    
    byte 25, 42, 25, 25
    byte 25, 43, 22, 14
    byte 14, 32, 22, 14
tile_palette_data_size = . - tile_palette_data
sprite_data:    
; vertical head
${tile(`
03311300
31111110
31122110
32211220
31211210
31111110
03111130
03111100
`)}
; horizontal head
${tile(`
00000000
03112110
11122113
11111211
11111211
11122113
33112110
00333330
`)}
; vertical tail
${tile(`
31122110
03111130
03111100
03111100
00311300
00311000
00311000
00033000
`)}
; horizontal tail
${tile(`
00000000
10000000
11110000
21111110
21111110
11113330
13330000
30000000
`)}
; underneath the tail
${tile(`
11111111
11111111
11111111
11111111
11111111
11111111
11111111
11111111
`)}
sprite_data_size = . - sprite_data
sprite_palette_data:    
    byte 25, 43, 22, 14 ; snake
    byte 22, 22, 22, 22 ; apple
    byte 25, 25, 25, 25 ; underneath tail
sprite_palette_data_size = . - sprite_palette_data
`;

const subroutines = () => asm`
init_board:
    SUBROUTINE
.init_tile_map:
    lda #$00
    ldx #$FF
.init_tile_map_loop_0:
    sta TPATM,x
    dex
    bne .init_tile_map_loop_0
    sta TPATM,x

    ldx #$FF
.init_tile_map_loop_1:
    sta TPATM+$100,x
    dex
    bne .init_tile_map_loop_1
    sta TPATM+$100,x

    ldx #$FF
.init_tile_map_loop_2:
    sta TPATM+$200,x
    dex
    bne .init_tile_map_loop_2
    sta TPATM+$200,x

    ldx #$FF
.init_tile_map_loop_3:
    sta TPATM+$300,x
    dex
    bne .init_tile_map_loop_3
    sta TPATM+$300,x

.init_tile_palettes:
    lda #$00
    ldx #$FF
.init_tile_palettes_loop:
    sta TPALM,x
    dex
    bne .init_tile_palettes_loop
    sta TPALM,x
.init_ui_tile_palettes:
    lda #$AA
    ldx #$07
.init_ui_tile_palettes_loop:
    sta TPALM,x
    dex
    bne .init_ui_tile_palettes_loop
    sta TPALM,x
.init_ui_tiles:
    lda #${FONT(' ')}
    ldx #$1f
.init_ui_tiles_loop:
    sta TPATM,x
    dex
    bne .init_ui_tiles_loop
    sta TPATM,x
.end:
    rts
`;

export { init, readOnlyData, subroutines };
