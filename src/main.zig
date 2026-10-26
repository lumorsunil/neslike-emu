const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rl = @import("raylib");
const ifc = @import("interface.zig");
const Byte = ifc.Byte;
const Computer = @import("computer.zig").Computer;
const Memory = @import("memory.zig").Memory;
const Controller = @import("controller.zig").Controller;
const Startup = @import("startup.zig").Startup;
const Graphics = @import("graphics.zig").Graphics;
const Audio = @import("audio.zig").Audio;
const Drive = @import("drive.zig").Drive;
const Randomizer = @import("randomizer.zig").Randomizer;
const Debug = @import("debug.zig").Debug;
const MemoryMap = @import("memory-map.zig").MemoryMap;
const UI = @import("ui.zig");

const tile = [16]u8{
    0b00_00_00_00, 0b00_00_00_00,
    0b01_01_01_00, 0b00_01_01_01,
    0b10_10_01_00, 0b00_01_10_10,
    0b11_10_01_00, 0b00_01_10_11,
    0b11_10_01_00, 0b00_01_10_11,
    0b10_10_01_00, 0b00_01_10_10,
    0b01_01_01_00, 0b00_01_01_01,
    0b00_00_00_00, 0b00_00_00_00,
};

const tile2 = [16]u8{
    0b00_00_00_00, 0b00_00_00_00,
    0b00_01_01_01, 0b01_01_01_00,
    0b00_01_10_10, 0b10_10_01_00,
    0b00_01_10_11, 0b11_10_01_00,
    0b00_01_10_11, 0b11_10_01_00,
    0b00_01_10_10, 0b10_10_01_00,
    0b00_01_01_01, 0b01_01_01_00,
    0b00_00_00_00, 0b00_00_00_00,
};

pub fn main(init: std.process.Init) !void {
    var ctx: MainContext = undefined;
    try initEmu(init.io, init.gpa, &ctx);
    defer deinitEmu(init.gpa, &ctx);

    while (!rl.windowShouldClose()) {
        try loop(&ctx);
    }
}

fn initEmu(io: std.Io, allocator: Allocator, ctx: *MainContext) !void {
    ctx.* = MainContext{
        .random = std.Random.IoSource{ .io = io },
        .file = try std.Io.Dir.cwd().readFileAlloc(io, "test.bin", allocator, .unlimited),
    };

    rl.initWindow(UI.screen_size[0], UI.screen_size[1], "Core Killer");
    rl.initAudioDevice();
    rl.setWindowFocused();
    rl.setWindowPosition(24, 24);
    // rl.setTargetFPS(60 * 2);

    initStartupChip(ctx);
    initMemoryChip(ctx);
    initDriveChip(ctx);
    initRandomizerChip(ctx);
    try initGraphicsChip(ctx);
    try initMemoryRenderBuffers(ctx);
    try initTextures(ctx);
    try initAudio(ctx);
    initDebugChip(ctx);

    drawMemoryRenderBufferBackgrounds(ctx);
}

fn deinitEmu(allocator: Allocator, ctx: *MainContext) void {
    allocator.free(ctx.file);
    rl.closeWindow();
    rl.closeAudioDevice();
}

fn restartComputer(ctx: *MainContext) void {
    ctx.is_continuing = false;
    restartCpuChip(ctx);
    restartStartupChip(ctx);
    restartMemoryChip(ctx);
    restartDriveChip(ctx);
    restartRandomizerChip(ctx);
    restartGraphicsChip(ctx);
    restartAudio(ctx);
    restartDebugChip(ctx);

    drawMemoryRenderBufferBackgrounds(ctx);
}

fn restartCpuChip(ctx: *MainContext) void {
    ctx.computer.cpu = .{};
}

fn initStartupChip(ctx: *MainContext) void {
    restartStartupChip(ctx);
}

fn restartStartupChip(ctx: *MainContext) void {
    ctx.computer.modules.get(Startup).chip.memory[0] = 0x00;
    ctx.computer.modules.get(Startup).chip.memory[1] = 0xD0;
}

fn initMemoryChip(ctx: *MainContext) void {
    restartMemoryChip(ctx);
}

fn restartMemoryChip(ctx: *MainContext) void {
    ctx.random.interface().bytes(&ctx.computer.modules.get(Memory).chip.memory);
}

fn initDriveChip(ctx: *MainContext) void {
    restartDriveChip(ctx);
}

fn restartDriveChip(ctx: *MainContext) void {
    for (0..ctx.file.len) |i| {
        ctx.computer.modules.get(Drive).chip.memory[i] = ctx.file[i];
    }
}

fn initRandomizerChip(ctx: *MainContext) void {
    restartRandomizerChip(ctx);
}

fn restartRandomizerChip(ctx: *MainContext) void {
    ctx.computer.modules.get(Randomizer).chip.random = .init(ctx.random.interface().int(u64));
}

fn initGraphicsChip(ctx: *MainContext) !void {
    const graphics = ctx.computer.modules.get(Graphics);

    graphics.chip.screen_buffer = try rl.loadRenderTexture(256, 256);
    graphics.chip.background_layer_buffer = try rl.loadRenderTexture(256, 256);

    restartGraphicsChip(ctx);
}

fn restartGraphicsChip(ctx: *MainContext) void {
    const graphics = ctx.computer.modules.get(Graphics);
    ctx.random.interface().bytes(&graphics.chip.memory);

    drawRandomPixels(ctx, graphics.chip.screen_buffer);
    drawRandomPixels(ctx, graphics.chip.background_layer_buffer);
}

fn drawRandomPixels(ctx: *MainContext, render_texture: rl.RenderTexture2D) void {
    render_texture.begin();
    for (0..@intCast(render_texture.texture.width)) |x| {
        for (0..@intCast(render_texture.texture.height)) |y| {
            const r = ctx.random.interface().int(u8);
            const color = rl.Color.init(r, r, r, 0xFF);
            rl.drawPixel(@intCast(x), @intCast(y), color);
        }
    }
    render_texture.end();
}

fn initTextures(ctx: *MainContext) !void {
    ctx.textures = Textures{
        .directional_button = try rl.loadRenderTexture(4, 4),
        .directional_button_src = rl.Rectangle.init(0, 0, 4, -4),
        .button = try rl.loadRenderTexture(4, 4),
        .button_src = rl.Rectangle.init(0, 0, 4, -4),
    };

    ctx.textures.directional_button.begin();
    for (0..4) |x| {
        for (0..4) |y| {
            if (y == 0 and (x == 0 or x == 3)) continue;
            rl.drawPixel(@intCast(x), @intCast(y), .white);
        }
    }
    ctx.textures.directional_button.end();

    ctx.textures.button.begin();
    for (0..4) |x| {
        for (0..4) |y| {
            if (y == 0 and (x == 0 or x == 3)) continue;
            if (y == 3 and (x == 0 or x == 3)) continue;
            rl.drawPixel(@intCast(x), @intCast(y), .white);
        }
    }
    ctx.textures.button.end();
}

fn initAudio(ctx: *MainContext) !void {
    const audio = ctx.computer.modules.get(Audio);
    // rl.setAudioStreamBufferSizeDefault(Audio.audio_buffer_size);
    audio.chip.audio_stream = try rl.loadAudioStream(Audio.sample_rate, 32, 1);
    Audio.self_ = &audio.chip;
    rl.setAudioStreamCallback(audio.chip.audio_stream, Audio.audioStreamCallback);
    // rl.attachAudioStreamProcessor(audio.chip.audio_stream, Audio.audioStreamCallback);
    ctx.random.interface().bytes(&audio.chip.noise_lut);
    rl.playAudioStream(audio.chip.audio_stream);
    rl.setMasterVolume(0.5);
    restartAudio(ctx);
}

fn restartAudio(ctx: *MainContext) void {
    const audio = ctx.computer.modules.get(Audio);
    audio.chip.initMemory();
}

fn initDebugChip(ctx: *MainContext) void {
    restartDebugChip(ctx);
}

fn restartDebugChip(ctx: *MainContext) void {
    ctx.computer.modules.get(Debug).chip.cpu = &ctx.computer.cpu;
}

fn initMemoryRenderBuffers(ctx: *MainContext) !void {
    ctx.memory_render_buffer = try rl.loadRenderTexture(UI.memory_cell_cols * 3, UI.memory_cell_rows * 3);
    ctx.memory_src = rl.Rectangle.init(0, 0, @floatFromInt(ctx.memory_render_buffer.texture.width), @floatFromInt(-ctx.memory_render_buffer.texture.height));
    ctx.memory_dst = rl.Rectangle.init(UI.memory_offset[0], UI.memory_offset[1], ctx.memory_src.width * ctx.memory_scale, ctx.memory_src.height * ctx.memory_scale);

    ctx.sprite_map_render_buffer = try rl.loadRenderTexture(UI.sprite_map_cell_cols * 3, UI.sprite_map_cell_rows * 3);
    ctx.sprite_map_src = rl.Rectangle.init(0, 0, @floatFromInt(ctx.sprite_map_render_buffer.texture.width), @floatFromInt(-ctx.sprite_map_render_buffer.texture.height));
    ctx.sprite_map_dst = rl.Rectangle.init(UI.sprite_map_offset[0], UI.sprite_map_offset[1], ctx.sprite_map_src.width * ctx.sprite_map_scale, ctx.sprite_map_src.height * ctx.sprite_map_scale);

    ctx.tile_map_render_buffer = try rl.loadRenderTexture(UI.tile_map_cell_cols * 3, UI.tile_map_cell_rows * 3);
    ctx.tile_map_src = rl.Rectangle.init(0, 0, @floatFromInt(ctx.tile_map_render_buffer.texture.width), @floatFromInt(-ctx.tile_map_render_buffer.texture.height));
    ctx.tile_map_dst = rl.Rectangle.init(UI.tile_map_offset[0], UI.tile_map_offset[1], ctx.tile_map_src.width * ctx.tile_map_scale, ctx.tile_map_src.height * ctx.tile_map_scale);

    ctx.tile_palette_map_render_buffer = try rl.loadRenderTexture(UI.tile_palette_map_cell_cols * 3, UI.tile_palette_map_cell_rows * 3);
    ctx.tile_palette_map_src = rl.Rectangle.init(0, 0, @floatFromInt(ctx.tile_palette_map_render_buffer.texture.width), @floatFromInt(-ctx.tile_palette_map_render_buffer.texture.height));
    ctx.tile_palette_map_dst = rl.Rectangle.init(UI.tile_palette_map_offset[0], UI.tile_palette_map_offset[1], ctx.tile_palette_map_src.width * ctx.tile_palette_map_scale, ctx.tile_palette_map_src.height * ctx.tile_palette_map_scale);
}

fn drawMemoryRenderBufferBackgrounds(ctx: *MainContext) void {
    ctx.memory_render_buffer.begin();
    // ctx.computer.modules.get(Memory).write_events = .full;
    drawMemoryAsCells(&ctx.computer, true);
    ctx.memory_render_buffer.end();

    ctx.sprite_map_render_buffer.begin();
    drawSpriteMapAsCells(&ctx.computer, true);
    ctx.sprite_map_render_buffer.end();

    ctx.tile_map_render_buffer.begin();
    drawTileMapAsCells(&ctx.computer, true);
    ctx.tile_map_render_buffer.end();

    ctx.tile_palette_map_render_buffer.begin();
    drawTilePaletteMapAsCells(&ctx.computer, true);
    ctx.tile_palette_map_render_buffer.end();
}

const MainContext = struct {
    is_continuing: bool = false,
    is_fullscreen: bool = true,
    file: []const u8,
    random: std.Random.IoSource,
    computer: Computer = .{},

    frame_count: usize = 0,
    time: struct {
        current: f64 = 0,
        previous: f64 = 0,
        draw: f64 = 0,
        update: f64 = 0,
        target: f64 = 1.0 / 60.0,
        frame: f64 = 0,

        fn begin(self: *@This()) void {
            self.current = rl.getTime(); // Number of elapsed seconds since InitTimer()
            self.update = self.current - self.previous;
            self.previous = self.current;
        }

        fn end(self: *@This()) void {
            // Frame time control system
            self.current = rl.getTime();
            self.draw = self.current - self.previous;
            self.previous = self.current;

            self.frame = self.update + self.draw;

            // Wait for some milliseconds...
            if (self.frame < self.target) {
                rl.waitTime(self.target - self.frame);

                self.current = rl.getTime();
                const wait_time: f64 = self.current - self.previous;
                self.previous = self.current;

                self.frame += wait_time; // Total frame time: update + draw + wait
            }
        }
    } = .{},

    textures: Textures = undefined,

    memory_render_buffer: rl.RenderTexture2D = undefined,
    memory_scale: f32 = 3,
    memory_src: rl.Rectangle = undefined,
    memory_dst: rl.Rectangle = undefined,

    sprite_map_render_buffer: rl.RenderTexture2D = undefined,
    sprite_map_scale: f32 = 3,
    sprite_map_src: rl.Rectangle = undefined,
    sprite_map_dst: rl.Rectangle = undefined,

    tile_map_render_buffer: rl.RenderTexture2D = undefined,
    tile_map_scale: f32 = 3,
    tile_map_src: rl.Rectangle = undefined,
    tile_map_dst: rl.Rectangle = undefined,

    tile_palette_map_render_buffer: rl.RenderTexture2D = undefined,
    tile_palette_map_scale: f32 = 3,
    tile_palette_map_src: rl.Rectangle = undefined,
    tile_palette_map_dst: rl.Rectangle = undefined,
};

fn loop(ctx: *MainContext) !void {
    ctx.time.begin();
    defer ctx.time.end();

    switch (try updateEmuControls(ctx)) {
        .cont => {},
        .restart => {
            restartComputer(ctx);
            return;
        },
    }
    updateMemoryRenderBuffers(ctx);

    rl.beginDrawing();
    rl.clearBackground(.black);

    drawCpu(ctx.computer);
    try drawController(ctx.computer, ctx.textures);
    drawMemory(ctx);

    const graphics = ctx.computer.modules.get(Graphics);
    const screen_scale: f32 = if (ctx.is_fullscreen) 4 else 2;
    const screen_dst = rl.Rectangle.init(UI.screen_size[0] - 256 * screen_scale, 0, 256 * screen_scale, 256 * screen_scale);
    graphics.chip.drawScreen(screen_dst);

    rl.drawFPS(5, UI.screen_size[1] - 20);

    rl.endDrawing();
}

const EmuEvent = enum { cont, restart };

fn updateEmuControls(ctx: *MainContext) !EmuEvent {
    if (rl.isKeyPressed(.r)) {
        return .restart;
    }

    if (rl.isKeyPressed(.f11)) {
        ctx.is_fullscreen = !ctx.is_fullscreen;
    }

    if (ctx.is_continuing) {
        if (rl.isKeyPressed(.f5)) {
            ctx.is_continuing = false;
        } else {
            for (0..Computer.clock_cycles_per_frame) |_| {
                try ctx.computer.step();
                const debug = &ctx.computer.modules.get(Debug).chip;
                if (debug.is_stop) {
                    ctx.is_continuing = false;
                    debug.is_stop = false;
                    break;
                }
            }
            try ctx.computer.stepFrame();
        }
    } else {
        if (rl.isKeyPressed(.f10)) {
            try ctx.computer.step();
        }
        if (rl.isKeyPressed(.f9)) {
            for (0..Computer.clock_cycles_per_frame) |_| {
                try ctx.computer.step();
                const debug = &ctx.computer.modules.get(Debug).chip;
                if (debug.is_stop) {
                    debug.is_stop = false;
                    break;
                }
            }
            try ctx.computer.stepFrame();
        }
        if (rl.isKeyPressed(.f5)) {
            ctx.is_continuing = true;
        }
    }

    return .cont;
}

fn updateMemoryRenderBuffers(ctx: *MainContext) void {
    ctx.memory_render_buffer.begin();
    drawMemoryAsCells(&ctx.computer, false);
    ctx.memory_render_buffer.end();

    ctx.sprite_map_render_buffer.begin();
    drawSpriteMapAsCells(&ctx.computer, false);
    ctx.sprite_map_render_buffer.end();

    ctx.tile_map_render_buffer.begin();
    drawTileMapAsCells(&ctx.computer, false);
    ctx.tile_map_render_buffer.end();

    ctx.tile_palette_map_render_buffer.begin();
    drawTilePaletteMapAsCells(&ctx.computer, false);
    ctx.tile_palette_map_render_buffer.end();
}

fn drawMemory(ctx: *MainContext) void {
    ctx.memory_render_buffer.texture.drawPro(ctx.memory_src, ctx.memory_dst, .zero(), 0, .white);
    ctx.sprite_map_render_buffer.texture.drawPro(ctx.sprite_map_src, ctx.sprite_map_dst, .zero(), 0, .white);
    ctx.tile_map_render_buffer.texture.drawPro(ctx.tile_map_src, ctx.tile_map_dst, .zero(), 0, .white);
    ctx.tile_palette_map_render_buffer.texture.drawPro(ctx.tile_palette_map_src, ctx.tile_palette_map_dst, .zero(), 0, .white);
}

fn drawCpu(computer: Computer) void {
    const font_char_width: usize = @intCast(rl.measureText("X", UI.font_size));
    const col_width: usize = font_char_width * (4 + 2);
    var buf: [16]u8 = undefined;

    const registers_to_draw = .{ .a, .x, .y, .pc };

    inline for (registers_to_draw, 0..) |field, i| {
        const x = (i % 2) * col_width;
        const y = @divFloor(i, 2) * UI.font_size;
        const label = @tagName(field);
        const data = @field(computer.cpu.registers, label);
        const text = std.fmt.bufPrintZ(&buf, "{s}: {f}", .{ label, data }) catch "err";
        rl.drawText(text, @intCast(x), @intCast(y), UI.font_size, .green);
    }
    {
        const x = 0;
        const y = 2 * UI.font_size;
        const label = "ir";
        const data = computer.cpu.instruction_register;
        const text = std.fmt.bufPrintZ(&buf, "{s}: {f}", .{ label, data }) catch "err";
        rl.drawText(text, @intCast(x), @intCast(y), UI.font_size, .green);
    }
    {
        const x = 0;
        const y = 3 * UI.font_size;
        const label = "ab";
        const data = computer.cpu.address_bus;
        const text = std.fmt.bufPrintZ(&buf, "{s}: {f}", .{ label, data }) catch "err";
        rl.drawText(text, @intCast(x), @intCast(y), UI.font_size, .green);
    }
    {
        const x = col_width + font_char_width * 2;
        const y = 3 * UI.font_size;
        const label = "db";
        const data = computer.cpu.data_bus;
        const text = std.fmt.bufPrintZ(&buf, "{s}: {f}", .{ label, data }) catch "err";
        rl.drawText(text, @intCast(x), @intCast(y), UI.font_size, .green);
    }
    {
        const x = 0;
        const y = 4 * UI.font_size;
        const label = "rw";
        const data = computer.cpu.read_write;
        const text = std.fmt.bufPrintZ(&buf, "{s}: {t}", .{ label, data }) catch "err";
        rl.drawText(text, @intCast(x), @intCast(y), UI.font_size, .green);
    }
}

fn drawMemoryAsText(computer: Computer) void {
    const cols = UI.memory_text_cols;
    const rows = UI.memory_text_rows;
    const font_char_width = rl.measureText("X", UI.font_size);
    const page_len = cols * rows;
    const page = @divFloor(computer.cpu.registers.pc.toInt(), page_len);
    const i_offset: usize = page * page_len;
    draw_memory: for (0..cols) |col| {
        for (0..rows) |row| {
            const i = col + row * cols + i_offset;
            const memory = computer.modules.getConst(Memory);
            if (i >= memory.memory.len) break :draw_memory;
            const byte = memory.memory[i];
            var buf: [16]u8 = undefined;
            const suffix = if (col % 2 == 1) " " else "";
            const text = std.fmt.bufPrintZ(&buf, "{x:02}{s}", .{ byte, suffix }) catch "err";
            const x_offset = if (col % 2 == 0) 0 else font_char_width * 2;
            const x: i32 = @as(i32, @intCast(@divFloor(col, 2))) * (font_char_width * 5) + x_offset + UI.memory_offset[0];
            const y: i32 = @as(i32, @intCast(row)) * (UI.font_size + 3) + UI.memory_offset[1];
            if (computer.cpu.registers.pc.toInt() == i) {
                rl.drawRectangle(x - 2, y - 2, font_char_width * 2 + 2, UI.font_size + 2, .green);
            }
            const color: rl.Color = if (computer.cpu.registers.pc.toInt() == i) .black else .green;
            rl.drawText(text, x, y, UI.font_size, color);
        }
    }
}

fn drawMemoryAsCells(computer: *Computer, draw_background: bool) void {
    const memory = computer.modules.get(Memory);
    const write_events = if (draw_background) brk: {
        var copy: @TypeOf(memory.write_events) = .full;
        break :brk &copy;
    } else &memory.write_events;

    drawMemoryCells(&memory.chip.memory, write_events, .{
        .cols = UI.memory_cell_cols,
        .color_override = if (draw_background) .gray else null,
        // .paged = .{
        //     .active_cell = computer.cpu.registers.pc.toInt(),
        //     .rows_per_page = UI.memory_cell_rows,
        // },
    });
}

fn drawTileMapAsCells(computer: *Computer, draw_background: bool) void {
    const graphics = computer.modules.get(Graphics);
    const chip_write_events = &graphics.chip.getModule(.tilePatternMap).write_events;
    var write_events_copy: @TypeOf(chip_write_events.*) = .full;
    const write_events = if (draw_background) &write_events_copy else chip_write_events;

    drawMemoryCells(graphics.chip.tileMap(), write_events, .{
        .cols = UI.tile_map_cell_cols,
        .color_override = if (draw_background) .gray else null,
    });
}

fn drawTilePaletteMapAsCells(computer: *Computer, draw_background: bool) void {
    const graphics = computer.modules.get(Graphics);
    const chip_write_events = &graphics.chip.getModule(.tilePaletteMap).write_events;
    var write_events_copy: @TypeOf(chip_write_events.*) = .full;
    const write_events: @TypeOf(chip_write_events) = if (draw_background) &write_events_copy else chip_write_events;

    drawMemoryCells(graphics.chip.tilePaletteMap(), write_events, .{
        .cols = UI.tile_palette_map_cell_cols,
        .color_override = if (draw_background) .gray else null,
    });
}

fn drawTilePalettesAsCells(computer: *Computer, draw_background: bool) void {
    const graphics = computer.modules.get(Graphics);
    const chip_write_events = &graphics.chip.getModule(.tilePalettes).write_events;
    var write_events_copy: @TypeOf(chip_write_events.*) = .full;
    const write_events = if (draw_background) &write_events_copy else chip_write_events;

    drawMemoryCells(graphics.chip.tilePalettes(), write_events, .{
        .cols = UI.memory_cell_cols,
        .color_override = if (draw_background) .gray else null,
    });
}

fn drawSpritePalettesAsCells(computer: *Computer, draw_background: bool) void {
    const graphics = computer.modules.get(Graphics);
    const chip_write_events = &graphics.chip.getModule(.spritePalettes).write_events;
    var write_events_copy: @TypeOf(chip_write_events.*) = .full;
    const write_events = if (draw_background) &write_events_copy else chip_write_events;

    drawMemoryCells(graphics.chip.spritePalettes(), write_events, .{
        .cols = UI.memory_cell_cols,
        .color_override = if (draw_background) .gray else null,
    });
}

fn drawTileDataAsCells(computer: *Computer, draw_background: bool) void {
    const graphics = computer.modules.get(Graphics);
    const chip_write_events = &graphics.chip.getModule(.tileData).write_events;
    var write_events_copy: @TypeOf(chip_write_events.*) = .full;
    const write_events = if (draw_background) &write_events_copy else chip_write_events;

    drawMemoryCells(graphics.chip.tileData(), write_events, .{
        .cols = UI.tile_data_cell_cols,
        .color_override = if (draw_background) .gray else null,
    });
}

fn drawSpriteDataAsCells(computer: *Computer, draw_background: bool) void {
    const graphics = computer.modules.get(Graphics);
    const chip_write_events = &graphics.chip.getModule(.spriteData).write_events;
    var write_events_copy: @TypeOf(chip_write_events.*) = .full;
    const write_events = if (draw_background) &write_events_copy else chip_write_events;

    drawMemoryCells(graphics.chip.spriteData(), write_events, .{
        .cols = UI.memory_cell_cols,
        .color_override = if (draw_background) .gray else null,
    });
}

fn drawSpriteMapAsCells(computer: *Computer, draw_background: bool) void {
    const graphics = computer.modules.get(Graphics);
    const chip_write_events = &graphics.chip.getModule(.spriteMap).write_events;
    var write_events_copy: @TypeOf(chip_write_events.*) = .full;
    const write_events = if (draw_background) &write_events_copy else chip_write_events;

    drawMemoryCells(graphics.chip.spriteMap(), write_events, .{
        .cols = UI.sprite_map_cell_cols,
        .color_override = if (draw_background) .gray else null,
    });
}

const DrawMemoryCellsOptions = struct {
    cols: usize,
    color_override: ?rl.Color = null,
    debug: bool = false,
    paged: ?struct {
        active_cell: usize,
        rows_per_page: usize,
    } = null,

    fn pageInfo(self: @This(), len: usize) struct {
        rows: usize,
        i_offset: usize,
        active_cell: ?usize = null,
        page_len: ?usize = null,
    } {
        if (self.paged) |paged| {
            const page_len = self.cols * paged.rows_per_page;
            const page = @divFloor(paged.active_cell, page_len);

            return .{
                .rows = paged.rows_per_page,
                .i_offset = page * page_len,
                .page_len = page_len,
                .active_cell = paged.active_cell,
            };
        }

        return .{
            .rows = @divExact(len, self.cols),
            .i_offset = 0,
        };
    }
};

fn drawMemoryCells(memory: []const u8, write_events: anytype, options: DrawMemoryCellsOptions) void {
    const cols = options.cols;
    const cell_size = @Vector(2, u4){ 2, 2 };
    const page_info = options.pageInfo(memory.len);
    const one = @Vector(2, u1){ 1, 1 };

    var it = write_events.iterator(.{});
    while (it.next()) |i| {
        if (page_info.page_len) |page_len| {
            if (i < page_info.i_offset or i >= page_info.i_offset + page_len) {
                continue;
            }
        }

        const col = i % cols;
        const row = @divFloor(i, cols);

        if (i >= memory.len) break;

        const byte = memory[i];
        const col_row = @Vector(2, i32){ @intCast(col), @intCast(row) };
        const pos = col_row * (cell_size + one) + one;
        if (page_info.active_cell) |ac| if (ac == i) {
            rl.drawRectangle(pos[0] - 1, pos[1] - 1, cell_size[0] + 2, cell_size[1] + 2, .light_gray);
        };
        if (options.color_override) |color_override| {
            rl.drawRectangle(pos[0], pos[1], cell_size[0], cell_size[1], color_override);
        } else {
            drawMemoryCell(byte, pos[0], pos[1]);
        }
    }

    write_events.* = .empty;
}

fn drawMemoryCell(byte: u8, offset_x: i32, offset_y: i32) void {
    const color_tl, const color_tr, const color_bl, const color_br = byteToColor(byte);
    rl.drawPixel(offset_x, offset_y, color_tl);
    rl.drawPixel(offset_x + 1, offset_y, color_tr);
    rl.drawPixel(offset_x, offset_y + 1, color_bl);
    rl.drawPixel(offset_x + 1, offset_y + 1, color_br);
}

fn byteToColor(byte: u8) struct { rl.Color, rl.Color, rl.Color, rl.Color } {
    const color_table = [4]rl.Color{ .blue, .green, .yellow, .red };

    return .{
        color_table[@as(u2, @truncate(byte >> 6))],
        color_table[@as(u2, @truncate(byte >> 4))],
        color_table[@as(u2, @truncate(byte >> 2))],
        color_table[@as(u2, @truncate(byte))],
    };
}

const Textures = struct {
    directional_button: rl.RenderTexture,
    directional_button_src: rl.Rectangle,
    button: rl.RenderTexture,
    button_src: rl.Rectangle,
};

fn drawController(computer: Computer, textures: Textures) !void {
    var offset_x: f32 = 300;
    const offset_y = 20;
    const scale = 3;
    const step = 16;
    const buttons = Byte.fromInt(try computer.modules.getConst(Controller).chip.read(0));

    {
        const x = 0;
        const y = 0;
        const data = buttons.b0;
        const src = textures.directional_button_src;
        var dst = src;
        dst.x = x + offset_x;
        dst.y = y + offset_y;
        dst.width *= scale;
        dst.height *= -scale;
        const color: rl.Color = if (data == 1) .yellow else .gray;
        textures.directional_button.texture.drawPro(textures.directional_button_src, dst, .zero(), 0, color);
    }
    {
        const x = -step;
        const y = step;
        const data = buttons.b1;
        const src = textures.directional_button_src;
        var dst = src;
        dst.width *= scale;
        dst.height *= -scale;
        dst.x = x + offset_x;
        dst.y = y + offset_y + dst.height;
        const color: rl.Color = if (data == 1) .yellow else .gray;
        textures.directional_button.texture.drawPro(textures.directional_button_src, dst, .zero(), 270, color);
    }
    {
        const x = 0;
        const y = step * 2;
        const data = buttons.b2;
        const src = textures.directional_button_src;
        var dst = src;
        dst.width *= scale;
        dst.height *= -scale;
        dst.x = x + offset_x + dst.width;
        dst.y = y + offset_y + dst.height;
        const color: rl.Color = if (data == 1) .yellow else .gray;
        textures.directional_button.texture.drawPro(textures.directional_button_src, dst, .zero(), 180, color);
    }
    {
        const x = step;
        const y = step;
        const data = buttons.b3;
        const src = textures.directional_button_src;
        var dst = src;
        dst.width *= scale;
        dst.height *= -scale;
        dst.x = x + offset_x + dst.width;
        dst.y = y + offset_y;
        const color: rl.Color = if (data == 1) .yellow else .gray;
        textures.directional_button.texture.drawPro(textures.directional_button_src, dst, .zero(), 90, color);
    }

    offset_x += step * 4;

    {
        const x = 0;
        const y = 0;
        const data = buttons.b4;
        const src = textures.button_src;
        var dst = src;
        dst.x = x + offset_x;
        dst.y = y + offset_y;
        dst.width *= scale;
        dst.height *= -scale;
        const color: rl.Color = if (data == 1) .yellow else .gray;
        textures.button.texture.drawPro(textures.button_src, dst, .zero(), 0, color);
    }
    {
        const x = -step;
        const y = step;
        const data = buttons.b5;
        const src = textures.button_src;
        var dst = src;
        dst.width *= scale;
        dst.height *= -scale;
        dst.x = x + offset_x;
        dst.y = y + offset_y + dst.height;
        const color: rl.Color = if (data == 1) .yellow else .gray;
        textures.button.texture.drawPro(textures.button_src, dst, .zero(), 270, color);
    }
    {
        const x = 0;
        const y = step * 2;
        const data = buttons.b6;
        const src = textures.button_src;
        var dst = src;
        dst.width *= scale;
        dst.height *= -scale;
        dst.x = x + offset_x + dst.width;
        dst.y = y + offset_y + dst.height;
        const color: rl.Color = if (data == 1) .yellow else .gray;
        textures.button.texture.drawPro(textures.button_src, dst, .zero(), 180, color);
    }
    {
        const x = step;
        const y = step;
        const data = buttons.b7;
        const src = textures.button_src;
        var dst = src;
        dst.width *= scale;
        dst.height *= -scale;
        dst.x = x + offset_x + dst.width;
        dst.y = y + offset_y;
        const color: rl.Color = if (data == 1) .yellow else .gray;
        textures.button.texture.drawPro(textures.button_src, dst, .zero(), 90, color);
    }
}

test {
    std.testing.refAllDecls(@This());
}
