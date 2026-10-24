import { asm } from "./asm.js";

const init = () => asm`
init_graphics:

init_tile_data:
    ldx #tile_data_size-1
tile_data_store:
    lda tile_data,x
    sta TDAT,x
    dex
    bpl tile_data_store

init_sprite_data:
    ldx #sprite_data_size-1
sprite_data_store:
    lda sprite_data,x
    sta SDAT,x
    dex
    bpl sprite_data_store

init_tile_palette_data:
    ldx #tile_palette_data_size-1
tile_palette_data_store:
    lda tile_palette_data,x
    sta TPAL,x
    dex
    bpl tile_palette_data_store

init_sprite_palette_data:
    ldx #sprite_palette_data_size-1
sprite_palette_data_store:
    lda sprite_palette_data,x
    sta SPAL,x
    dex
    bpl sprite_palette_data_store

init_tile_map:
    lda #$00
    ldx #$FF
init_tile_map_loop_0:
    sta TPATM,x
    dex
    bne init_tile_map_loop_0
    sta TPATM,x

    ldx #$FF
init_tile_map_loop_1:
    sta TPATM+$100,x
    dex
    bne init_tile_map_loop_1
    sta TPATM+$100,x

    ldx #$FF
init_tile_map_loop_2:
    sta TPATM+$200,x
    dex
    bne init_tile_map_loop_2
    sta TPATM+$200,x

    ldx #$FF
init_tile_map_loop_3:
    sta TPATM+$300,x
    dex
    bne init_tile_map_loop_3
    sta TPATM+$300,x

init_tile_palettes:
    lda #$00
    ldx #$FF
init_tile_palettes_loop:
    sta TPALM,x
    dex
    bne init_tile_palettes_loop
    sta TPALM,x

init_sprites:
    lda #0
    ldx #$FF
init_sprites_loop:
    sta SMAP,x
    dex
    bne init_sprites_loop
    sta SMAP,x
`;

const data = () => asm`
tile_data:    
    byte 0, 0, 0, 1, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 1, 0
tile_data_size = . - tile_data
tile_palette_data:    
    byte 25, 42, 25, 25
tile_palette_data_size = . - tile_palette_data
sprite_data:    
    byte $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF, $FF
sprite_data_size = . - sprite_data
sprite_palette_data:    
    byte 39, 39, 39, 39
    byte 22, 22, 22, 22
sprite_palette_data_size = . - sprite_palette_data
`;

export { init, data };
