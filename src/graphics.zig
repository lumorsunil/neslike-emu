const std = @import("std");
const ifc = @import("interface.zig");
const rl = @import("raylib");
const UI = @import("ui.zig");
const Module = @import("module.zig").Module;
const ModuleCollection = @import("module.zig").ModuleCollection;

// TODO: Universal background color layer (each tile's palette color 0)
// TODO: Background tile transparency (color 0)
// TODO: Sprite layers (behind/in front of background tiles)
// TODO: Sprite flip
pub const Graphics = struct {
    rdy: u1 = 1,
    /// memory:             0x0000 - 0x2FFF
    /// tile pattern map:   0x0000 - 0x03FF  (32 * 32 * 8bits)
    /// tile palette map:   0x0400 - 0x04FF  (32 * 32 * 2bits)
    /// tile palettes:      0x0500 - 0x050F  (4 * 4 * (6bits + [2bits padding]))
    /// sprite palettes:    0x0510 - 0x051f  (4 * 4 * (6bits + [2bits padding]))
    /// tile data:          0x0520 - 0x151f  (256 * 8 * 8 * 2bits) (256 * 16bytes)
    /// sprite data:        0x1520 - 0x251f  (256 * 8 * 8 * 2bits) (256 * 16bytes)
    /// sprites             0x2520 - 0x261f  (64 * 32bits)
    /// vsync               0x2620
    memory: [memory_len - virtual_memory_len]u8 = undefined,
    // sprites: [sprites_len]Sprite = undefined,
    screen_buffer: rl.RenderTexture2D = undefined,
    background_layer_buffer: rl.RenderTexture2D = undefined,
    background_render_queue: std.bit_set.ArrayBitSet(usize, tiles_len) = .empty,
    modules: ModuleCollection(.{
        TilePatternMap,
        TilePaletteMap,
        TilePaletteData,
        SpritePaletteData,
        TileData,
        SpriteData,
        SpriteMap,
        VsyncModule,
    }) = .init(.{
        .init(0), // tile pattern map
        .init(0x0400), // tile palette map
        .init(0x0500), // tile palette data
        .init(0x0510), // sprite palette data
        .init(0x0520), // tile data
        .init(0x1520), // sprite data
        .init(0x2520), // sprite map
        .init(0x2620), // vsync
    }),

    const screen_scale = 2;
    const screen_src = rl.Rectangle.init(0, 0, 256, -256);
    const screen_dst = rl.Rectangle.init(UI.screen_size[0] - 256 * screen_scale, 0, 256 * screen_scale, 256 * screen_scale);

    const master_palette = [64]rl.Color{
        .init(0x54, 0x54, 0x54, 0xFF), // (84, 84, 84) — Medium Dark Gray
        .init(0x00, 0x1D, 0x74, 0xFF), // (0, 29, 116) — Deep Blue
        .init(0x00, 0x0F, 0x97, 0xFF), // (0, 15, 151) — Dark Blue
        .init(0x34, 0x00, 0x8E, 0xFF), // (52, 0, 142) — Dark Purple
        .init(0x50, 0x00, 0x67, 0xFF), // (80, 0, 103) — Dark Magenta
        .init(0x5E, 0x00, 0x26, 0xFF), // (94, 0, 38) — Dark Red-Magenta
        .init(0x4F, 0x0D, 0x00, 0xFF), // (79, 13, 0) — Dark Red (Maroon)
        .init(0x38, 0x20, 0x00, 0xFF), // (56, 32, 0) — Dark Orange / Brown
        .init(0x1D, 0x32, 0x00, 0xFF), // (29, 50, 0) — Dark Olive Green
        .init(0x00, 0x3E, 0x00, 0xFF), // (0, 62, 0) — Dark Green
        .init(0x00, 0x3F, 0x00, 0xFF), // (0, 63, 0) — Dark Lime Green
        .init(0x00, 0x37, 0x21, 0xFF), // (0, 55, 33) — Dark Teal
        .init(0x00, 0x2D, 0x59, 0xFF), // (0, 45, 89) — Dark Cyan
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — "Blacker than Black" (Unsafe code; can distort old CRT signals)
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
        .init(0x92, 0x92, 0x92, 0xFF), // (146, 146, 146) — Medium Gray
        .init(0x00, 0x57, 0xAF, 0xFF), // (0, 87, 175) — Mega Man Blue
        .init(0x28, 0x38, 0xD6, 0xFF), // (40, 56, 214) — Royal Blue
        .init(0x5F, 0x19, 0xE3, 0xFF), // (95, 25, 227) — Vibrant Purple
        .init(0x8E, 0x0E, 0xA8, 0xFF), // (142, 14, 168) — Vibrant Magenta
        .init(0x9E, 0x14, 0x42, 0xFF), // (158, 20, 66) — Crimson
        .init(0x92, 0x27, 0x00, 0xFF), // (146, 39, 0) — Mario's Shirt Red
        .init(0x6F, 0x46, 0x00, 0xFF), // (111, 70, 0) — Dirt / Brick Brown
        .init(0x4A, 0x5F, 0x00, 0xFF), // (74, 95, 0) — Olive Green
        .init(0x00, 0x73, 0x00, 0xFF), // (0, 115, 0) — Luigi Green
        .init(0x00, 0x7B, 0x00, 0xFF), // (0, 123, 0) — Lime Green
        .init(0x00, 0x74, 0x41, 0xFF), // (0, 116, 65) — Teal / Green
        .init(0x00, 0x67, 0x8E, 0xFF), // (0, 103, 142) — Cyan
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
        .init(0xEC, 0xEC, 0xEC, 0xFF), // (236, 236, 236) — Light Gray / Off-White
        .init(0x39, 0x95, 0xFE, 0xFF), // (57, 149, 254) — Classic Sky Blue
        .init(0x6A, 0x73, 0xFF, 0xFF), // (106, 115, 255) — Light Slate Blue
        .init(0xA5, 0x57, 0xFF, 0xFF), // (165, 87, 255) — Bright Violet
        .init(0xD8, 0x51, 0xF6, 0xFF), // (216, 81, 246) — Bright Pink
        .init(0xE6, 0x5A, 0x96, 0xFF), // (230, 90, 150) — Rose Pink
        .init(0xD9, 0x6D, 0x39, 0xFF), // (217, 109, 57) — Light Red / Orange
        .init(0xB6, 0x8B, 0x18, 0xFF), // (182, 139, 24) — Sand / Gold
        .init(0x8A, 0x9F, 0x00, 0xFF), // (138, 159, 0) — Yellow-Green
        .init(0x49, 0xB9, 0x00, 0xFF), // (73, 185, 0) — Bright Lime
        .init(0x24, 0xC7, 0x2B, 0xFF), // (36, 199, 43) — Bright Green
        .init(0x1C, 0xC2, 0x74, 0xFF), // (28, 194, 116) — Bright Mint
        .init(0x1E, 0xB2, 0xBA, 0xFF), // (30, 178, 186) — Bright Turquoise
        .init(0x42, 0x42, 0x42, 0xFF), // (66, 66, 66) — Dark Charcoal Gray
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
        .init(0xFF, 0xFF, 0xFF, 0xFF), // (255, 255, 255) — Pure White
        .init(0xA4, 0xCE, 0xFE, 0xFF), // (164, 206, 254) — Pale Blue
        .init(0xB8, 0xBF, 0xFE, 0xFF), // (184, 191, 254) — Pale Lavender
        .init(0xD2, 0xAF, 0xFD, 0xFF), // (210, 175, 253) — Pale Purple
        .init(0xE6, 0xA6, 0xFE, 0xFF), // (230, 166, 254) — Pale Magenta
        .init(0xED, 0xA8, 0xD1, 0xFF), // (237, 168, 209) — Pale Pink
        .init(0xE7, 0xBC, 0xA2, 0xFF), // (231, 188, 162) — Peach / Light Skin Tone
        .init(0xD9, 0xCC, 0x9F, 0xFF), // (217, 204, 159) — Pale Yellow / Tan
        .init(0xC6, 0xD8, 0x97, 0xFF), // (198, 216, 151) — Pale Sage Green
        .init(0xAE, 0xDF, 0xA3, 0xFF), // (174, 223, 163) — Pale Mint Green
        .init(0xA0, 0xE4, 0xB7, 0xFF), // (160, 228, 183) — Pale Aqua
        .init(0x9E, 0xE2, 0xD9, 0xFF), // (158, 226, 217) — Pale Ice Blue
        .init(0x9D, 0xDC, 0xF0, 0xFF), // (157, 220, 240) — Pale Sky Blue
        .init(0xB4, 0xB4, 0xB4, 0xFF), // (180, 180, 180) — Silver / Pale Gray
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
        .init(0x00, 0x00, 0x00, 0xFF), // (0, 0, 0) — Black
    };

    pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
    pub const memory_len = 12288 + virtual_memory_len;
    const vsync = 0x2620;
    const virtual_memory_len = 1;
    const sprites_len = 64;
    const tile_cols = 32;
    const tile_rows = 32;
    const tiles_len = tile_cols * tile_rows;
    const TileQueueInt = std.math.IntFittingRange(0, tiles_len - 1);
    const tile_size = @Vector(2, u8){ 8, 8 };

    pub fn stepFrame(self: *@This()) Error!void {
        self.consumeTileQueue();
        self.screen_buffer.begin();
        self.drawBackgroundLayer();
        self.drawSprites();
        self.screen_buffer.end();
        self.rdy = 1;
    }

    pub fn read(self: @This(), addr: Addr) Error!u8 {
        return self.memory[addr];
    }

    pub fn write(self: *@This(), addr: Addr, data: u8) Error!void {
        inline for (&self.modules.modules) |*module| {
            if (module.memory_map.isMapped(Addr, addr)) |rel_addr| {
                module.write_events.set(rel_addr);
                @TypeOf(module.chip).write(.init(self, addr, rel_addr, data));
                break;
            }
        }
    }

    fn renderTile(self: *@This(), addr: Addr) void {
        // self.render_buffer.begin();
        const col: u8 = @truncate(addr % tile_cols);
        const row: u8 = @truncate(@divFloor(addr, tile_cols));
        self.drawTile(col, row, col * 8, row * 8);
        // self.render_buffer.end();
    }

    fn queueTile(self: *@This(), addr: Addr) void {
        self.background_render_queue.set(addr);
    }

    fn consumeTileQueue(self: *@This()) void {
        self.background_layer_buffer.begin();
        var it = self.background_render_queue.iterator(.{});
        while (it.next()) |index| {
            self.renderTile(@truncate(index));
        }
        self.background_render_queue = .empty;
        self.background_layer_buffer.end();
    }

    pub fn tileMap(self: *@This()) []u8 {
        return self.modules.get(TilePatternMap).memory_map.slice(&self.memory);
    }

    pub fn tilePaletteMap(self: *@This()) []u8 {
        return self.modules.get(TilePaletteMap).memory_map.slice(&self.memory);
    }

    fn tilePalettes(self: *@This()) []u8 {
        return self.modules.get(TilePaletteData).memory_map.slice(&self.memory);
    }

    fn spritePalettes(self: *@This()) []u8 {
        return self.modules.get(SpritePaletteData).memory_map.slice(&self.memory);
    }

    pub fn tileData(self: *@This()) []u8 {
        return self.modules.get(TileData).memory_map.slice(&self.memory);
    }

    fn spriteData(self: *@This()) []u8 {
        return self.modules.get(SpriteData).memory_map.slice(&self.memory);
    }

    pub fn spriteMap(self: *@This()) []u8 {
        return self.modules.get(SpriteMap).memory_map.slice(&self.memory);
    }

    fn getSprites(self: *@This()) []align(1) Sprite {
        return std.mem.bytesAsSlice(Sprite, self.spriteMap());
    }

    pub fn drawScreen(self: @This()) void {
        self.screen_buffer.texture.drawPro(screen_src, screen_dst, .zero(), 0, .white);
    }

    fn drawBackgroundLayer(self: *@This()) void {
        const src = rl.Rectangle.init(0, 0, 256, -256);
        const dst = rl.Rectangle.init(0, 0, 256, 256);
        rl.drawTexturePro(self.background_layer_buffer.texture, src, dst, .zero(), 0, .white);
    }

    fn drawTile(self: *@This(), col: u16, row: u16, offset_x: u8, offset_y: u8) void {
        const i = col + row * tile_cols;
        const tile_index = self.tileMap()[i];
        const pi = @divFloor(i, 4);
        const tile_palette_index: u2 = @truncate(self.tilePaletteMap()[pi] >> @truncate((i % 4) * 2));
        const tile_palette = self.tilePalettes()[@as(u16, tile_palette_index) * 4 .. @as(u16, tile_palette_index) * 4 + 4];

        for (0..8) |tile_data_row| {
            for (0..2) |tile_data_row_side| {
                const data = self.tileData()[@as(u16, tile_index) * 16 + tile_data_row * 2 + tile_data_row_side];

                for (0..4) |pixel| {
                    const palette_color: u2 = @truncate(data >> @truncate(pixel * 2));
                    const color_index: u6 = @truncate(tile_palette[palette_color]);
                    const color = master_palette[color_index];

                    const x = offset_x + pixel + tile_data_row_side * 4;
                    const y = offset_y + tile_data_row;

                    rl.drawPixel(@intCast(x), @intCast(y), color);
                }
            }
        }
    }

    fn drawSprites(self: *@This()) void {
        for (self.getSprites()) |sprite| {
            if (sprite.enabled == 0) continue;
            self.drawSprite(sprite);
        }
    }

    fn drawSprite(self: *@This(), sprite: Sprite) void {
        const palette = self.spritePalettes()[@as(u16, sprite.palette) * 4 .. @as(u16, sprite.palette) * 4 + 4];

        for (0..8) |tile_data_row| {
            for (0..2) |tile_data_row_side| {
                const data = self.tileData()[@as(u16, sprite.tile_index) * 16 + tile_data_row * 2 + tile_data_row_side];

                for (0..4) |pixel| {
                    const palette_color: u2 = @truncate(data >> @truncate(pixel * 2));
                    if (palette_color == 0) continue;
                    const color_index: u6 = @truncate(palette[palette_color]);
                    const color = master_palette[color_index];

                    const x = sprite.x + pixel + tile_data_row_side * 4;
                    const y = sprite.y + tile_data_row;

                    rl.drawPixel(@intCast(x), @intCast(y), color);
                }
            }
        }
    }

    const SubModuleTag = enum { tilePatternMap, spriteMap, tilePaletteMap, tileData, spriteData, spritePaletteData, tilePaletteData };
    const sub_module_map = std.enums.EnumFieldStruct(SubModuleTag, type, null){
        .tilePatternMap = TilePatternMap,
        .spriteMap = SpriteMap,
        .tilePaletteMap = TilePaletteMap,
        .tileData = TileData,
        .spriteData = SpriteData,
        .spritePaletteData = SpritePaletteData,
        .tilePaletteData = TilePaletteData,
    };

    pub fn getModule(self: *@This(), comptime sub_module: SubModuleTag) *Module(@field(sub_module_map, @tagName(sub_module))) {
        return self.modules.get(@field(sub_module_map, @tagName(sub_module)));
    }

    pub fn getModuleConst(self: *@This(), comptime sub_module: SubModuleTag) Module(@field(sub_module_map, @tagName(sub_module))) {
        return self.modules.getConst(@field(sub_module_map, @tagName(sub_module)));
    }

    const Sprite = packed struct(u32) {
        x: u8,
        y: u8,
        tile_index: u8,
        palette: u2,
        horizontal_flip: u1,
        vertical_flip: u1,
        priority_layer: enum(u1) {
            behind,
            front,

            pub fn fromInt(int: u1) @This() {
                return @enumFromInt(int);
            }

            pub fn toInt(self: @This()) u1 {
                return @intFromEnum(self);
            }
        },
        enabled: u1,
        _: u2,
    };

    const Tile = struct {
        pixels: [8 * 8]packed struct {
            color: u2,
        } = undefined,
    };

    pub const Error = error{};
};

pub const WriteContext = struct {
    graphics: *Graphics,
    addr: u16,
    rel_addr: u16,
    data: u8,

    pub fn init(graphics: *Graphics, addr: u16, rel_addr: u16, data: u8) @This() {
        return .{ .graphics = graphics, .addr = addr, .rel_addr = rel_addr, .data = data };
    }
};

pub fn VirtualModule(
    comptime memory_len_: u16,
    comptime write_: fn (WriteContext) void,
) type {
    return struct {
        pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
        pub const memory_len = memory_len_;

        pub const write = write_;
    };
}

pub fn WriterModule(comptime memory_len: u16) type {
    return VirtualModule(memory_len, writerWrite);
}
pub fn writerWrite(ctx: WriteContext) void {
    ctx.graphics.memory[ctx.addr] = ctx.data;
}

const TilePatternMap = VirtualModule(0x0400, tilePatternMapWrite);
pub fn tilePatternMapWrite(ctx: WriteContext) void {
    ctx.graphics.memory[ctx.addr] = ctx.data;
    ctx.graphics.queueTile(@intCast(ctx.rel_addr));
}

const TilePaletteMap = VirtualModule(0x0100, tilePaletteMapWrite);
pub fn tilePaletteMapWrite(ctx: WriteContext) void {
    ctx.graphics.memory[ctx.addr] = ctx.data;
    for (0..4) |i| ctx.graphics.queueTile(@intCast(ctx.rel_addr * 4 + @as(u16, @truncate(i))));
}

const TilePaletteData = WriterModule(0x0010);
const SpritePaletteData = WriterModule(0x0010);
const TileData = WriterModule(0x1000);
const SpriteData = WriterModule(0x1000);
const SpriteMap = WriterModule(0x0100);

const VsyncModule = VirtualModule(1, writeVsync);
fn writeVsync(ctx: WriteContext) void {
    ctx.graphics.rdy = 0;
}
