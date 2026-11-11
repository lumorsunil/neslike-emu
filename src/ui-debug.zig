const std = @import("std");
const rl = @import("raylib");
const UI = @import("ui.zig");
const Computer = @import("computer.zig").Computer;
const Debug = @import("debug.zig").Debug;
const MOS6502 = @import("6502.zig");
const ifc = @import("interface.zig");
const Byte = ifc.Byte;
const Nibble = ifc.Nibble;
const Controller = @import("controller.zig").Controller;

pub const UIDebugContext = struct {
    computer: *Computer,
    render_buffers: RenderBuffers,
    is_continuing: bool,
    is_fullscreen: bool,
    font: rl.Font,

    pub const RenderBuffers = struct {
        memory: RenderBuffer,
        sprite_map: RenderBuffer,
        tile_pattern_map: RenderBuffer,
        tile_palette_map: RenderBuffer,
        directional_button: RenderBuffer,
        button: RenderBuffer,
    };

    pub fn init(self: *@This()) !void {
        try initRenderBuffers(self);
        drawMemoryRenderBuffers(self, true);
    }

    pub fn restart(self: *@This()) void {
        self.is_continuing = false;
        drawMemoryRenderBuffers(self, true);
    }

    pub fn update(self: *@This()) !EmuEvent {
        const event = try updateEmuControls(self);
        drawMemoryRenderBuffers(self, false);

        return event;
    }

    pub fn draw(self: *@This()) !void {
        try drawCpu(self);
        try drawController(self);
        drawMemory(self);
        try drawInstructions(self);
    }
};

const RenderBuffer = struct {
    render_texture: rl.RenderTexture2D = undefined,
    src: rl.Rectangle = undefined,
    dst: rl.Rectangle = undefined,

    pub fn init(offset: @Vector(2, f32), size: @Vector(2, i32), scale: f32) !@This() {
        const render_texture = try rl.loadRenderTexture(size[0], size[1]);
        const fsize: @Vector(2, f32) = @floatFromInt(size);

        return .{
            .render_texture = render_texture,
            .src = rl.Rectangle.init(0, 0, fsize[0], -fsize[1]),
            .dst = rl.Rectangle.init(offset[0], offset[1], fsize[0] * scale, fsize[1] * scale),
        };
    }

    pub fn draw(self: @This()) void {
        self.render_texture.texture.drawPro(self.src, self.dst, .zero(), 0, .white);
    }

    pub fn drawEx(self: @This(), offset: @Vector(2, f32), r: f32, tint: rl.Color) void {
        var dst = self.dst;
        dst.x += offset[0];
        dst.y += offset[1];
        self.render_texture.texture.drawPro(self.src, dst, .zero(), r, tint);
    }
};

pub const EmuEvent = enum { cont, restart };

fn initRenderBuffers(ctx: *UIDebugContext) !void {
    try initMemoryRenderBuffers(ctx);
    try initControllerRenderBuffers(ctx);
}

fn initMemoryRenderBuffers(ctx: *UIDebugContext) !void {
    const scale = 3;
    const cell_pixels = @Vector(2, i32){ 3, 3 };

    const MemoryRenderBuffer = struct {
        pub fn init(offset: @Vector(2, f32), cols: i32, rows: i32) !RenderBuffer {
            return .init(offset, .{ cols * cell_pixels[0], rows * cell_pixels[1] }, scale);
        }
    };

    ctx.render_buffers.memory = try MemoryRenderBuffer.init(UI.memory_offset, UI.memory_cell_cols, UI.memory_cell_rows);
    ctx.render_buffers.sprite_map = try MemoryRenderBuffer.init(UI.sprite_map_offset, UI.sprite_map_cell_cols, UI.sprite_map_cell_rows);
    ctx.render_buffers.tile_pattern_map = try MemoryRenderBuffer.init(UI.tile_map_offset, UI.tile_map_cell_cols, UI.tile_map_cell_rows);
    ctx.render_buffers.tile_palette_map = try MemoryRenderBuffer.init(UI.tile_palette_map_offset, UI.tile_palette_map_cell_cols, UI.tile_palette_map_cell_rows);
}

fn initControllerRenderBuffers(ctx: *UIDebugContext) !void {
    ctx.render_buffers.directional_button = try .init(.{ 0, 0 }, .{ 4, 4 }, 3);
    ctx.render_buffers.button = try .init(.{ 0, 0 }, .{ 4, 4 }, 3);

    ctx.render_buffers.directional_button.render_texture.begin();
    for (0..4) |x| {
        for (0..4) |y| {
            if (y == 0 and (x == 0 or x == 3)) continue;
            rl.drawPixel(@intCast(x), @intCast(y), .white);
        }
    }
    ctx.render_buffers.directional_button.render_texture.end();

    ctx.render_buffers.button.render_texture.begin();
    for (0..4) |x| {
        for (0..4) |y| {
            if (y == 0 and (x == 0 or x == 3)) continue;
            if (y == 3 and (x == 0 or x == 3)) continue;
            rl.drawPixel(@intCast(x), @intCast(y), .white);
        }
    }
    ctx.render_buffers.button.render_texture.end();
}

fn updateEmuControls(ctx: *UIDebugContext) !EmuEvent {
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

fn drawMemoryRenderBuffers(ctx: *UIDebugContext, draw_background: bool) void {
    ctx.render_buffers.memory.render_texture.begin();
    drawMemoryAsCells(ctx.computer, draw_background);
    ctx.render_buffers.memory.render_texture.end();

    ctx.render_buffers.sprite_map.render_texture.begin();
    drawGraphicMemoryAsCells(ctx.computer, .spriteMap, UI.sprite_map_cell_cols, UI.sprite_map_cell_cols, draw_background);
    ctx.render_buffers.sprite_map.render_texture.end();

    ctx.render_buffers.tile_pattern_map.render_texture.begin();
    drawGraphicMemoryAsCells(ctx.computer, .tilePatternMap, UI.tile_map_cell_cols, UI.tile_map_cell_memory_cols, draw_background);
    ctx.render_buffers.tile_pattern_map.render_texture.end();

    ctx.render_buffers.tile_palette_map.render_texture.begin();
    drawGraphicMemoryAsCells(ctx.computer, .tilePaletteMap, UI.tile_palette_map_cell_cols, UI.tile_palette_map_cell_memory_cols, draw_background);
    ctx.render_buffers.tile_palette_map.render_texture.end();
}

fn drawMemory(ctx: *UIDebugContext) void {
    ctx.render_buffers.memory.draw();
    ctx.render_buffers.sprite_map.draw();
    ctx.render_buffers.tile_pattern_map.draw();
    ctx.render_buffers.tile_palette_map.draw();
}

fn drawCpu(ctx: *UIDebugContext) !void {
    const font_char_width: usize = (@intCast(rl.measureText("X", UI.font_size) + UI.text_spacing));
    const col_width: usize = font_char_width * (4 + 2);
    var buf: [32]u8 = undefined;

    const registers_to_draw = .{ .a, .x, .y, .pc, .s };
    const flags_to_draw = .{ .carry, .zero_, .decimal_mode, .overflow, .negative };
    const flag_tag_to_label = .{ "c", "z", "d", "o", "n" };

    inline for (registers_to_draw, 0..) |field, i| {
        const x = (i % 2) * col_width;
        const y = @divFloor(i, 2) * UI.font_size;
        const label = @tagName(field);
        const data = @field(ctx.computer.cpu.registers, label);
        const text = std.fmt.bufPrintZ(&buf, "{s}: {f}", .{ label, data }) catch "err";
        rl.drawTextEx(ctx.font, text, .init(@floatFromInt(x), @floatFromInt(y)), UI.font_size, UI.text_spacing, .green);
    }
    inline for (flags_to_draw, 0..) |field, i| {
        const width = font_char_width * 3;
        const x = i * width + 10 * font_char_width;
        const y = 4 * UI.font_size;
        const tag = @tagName(field);
        const label = flag_tag_to_label[i];
        const data = @field(ctx.computer.cpu.flags, tag);
        const text = std.fmt.bufPrintZ(&buf, "{s}:{}", .{ label, data }) catch "err";
        rl.drawTextEx(ctx.font, text, .init(@floatFromInt(x), @floatFromInt(y)), UI.font_size, UI.text_spacing, .green);
    }
    {
        const x = font_char_width * 6;
        const y = 2 * UI.font_size;
        const label = "ir";
        const data = ctx.computer.cpu.instruction_register;
        const decoded = brk: {
            if (ctx.computer.cpu.instr_addr) |addr| {
                const cartridge = ctx.computer.modules.getConst(Computer.CartridgeSlot);
                if (cartridge.isMapped(addr)) |rel_addr| {
                    const decoded, _ = MOS6502.Instruction.decode(cartridge.chip.memory[rel_addr..]) catch |err| switch (err) {
                        MOS6502.Instruction.DecodeError.InvalidOpcode => break :brk null,
                        else => return err,
                    };
                    break :brk decoded;
                }
            }
            break :brk null;
        };
        const text = std.fmt.bufPrintZ(&buf, "{s}: {f} {?f}", .{ label, data, decoded }) catch "err";
        rl.drawTextEx(ctx.font, text, .init(@floatFromInt(x), @floatFromInt(y)), UI.font_size, UI.text_spacing, .green);
    }
    {
        const x = 0;
        const y = 3 * UI.font_size;
        const label = "ab";
        const data = ctx.computer.cpu.address_bus;
        const text = std.fmt.bufPrintZ(&buf, "{s}: {f}", .{ label, data }) catch "err";
        rl.drawTextEx(ctx.font, text, .init(@floatFromInt(x), @floatFromInt(y)), UI.font_size, UI.text_spacing, .green);
    }
    {
        const x = col_width + font_char_width * 2;
        const y = 3 * UI.font_size;
        const label = "db";
        const data = ctx.computer.cpu.data_bus;
        const text = std.fmt.bufPrintZ(&buf, "{s}: {f}", .{ label, data }) catch "err";
        rl.drawTextEx(ctx.font, text, .init(@floatFromInt(x), @floatFromInt(y)), UI.font_size, UI.text_spacing, .green);
    }
    {
        const x = 0;
        const y = 4 * UI.font_size;
        const label = "rw";
        const data = ctx.computer.cpu.read_write;
        const text = std.fmt.bufPrintZ(&buf, "{s}: {t}", .{ label, data }) catch "err";
        rl.drawTextEx(ctx.font, text, .init(@floatFromInt(x), @floatFromInt(y)), UI.font_size, UI.text_spacing, .green);
    }
}

fn drawInstructions(ctx: *UIDebugContext) !void {
    var buf: [32]u8 = undefined;

    const x_offset = UI.instructions_offset[0];
    const y_offset = UI.instructions_offset[1];

    const start_addr = ctx.computer.cpu.instr_addr orelse {
        const pc = ctx.computer.cpu.registers.pc;
        const x = 0 + x_offset;
        const y = 0 + y_offset;
        const text = std.fmt.bufPrintZ(&buf, "{x:04}: ????", .{pc.toInt()}) catch "err";
        rl.drawTextEx(ctx.font, text, .init(@floatFromInt(x), @floatFromInt(y)), UI.font_size, UI.text_spacing, .green);
        return;
    };

    const drive = ctx.computer.modules.getConst(Computer.CartridgeSlot);
    var addr_cursor = start_addr;
    draw_instructions: for (0..UI.instructions_len) |i| {
        const instr_addr = addr_cursor;
        const x = 0 + x_offset;
        const y = i * UI.font_size + y_offset;
        const decoded: union(enum) {
            instr: MOS6502.Instruction,
            data: u8,
        } = brk: {
            if (drive.isMapped(addr_cursor)) |rel_addr| {
                const decoded, const len = MOS6502.Instruction.decode(drive.chip.memory[rel_addr..]) catch |err| switch (err) {
                    MOS6502.Instruction.DecodeError.InvalidOpcode => break :brk .{ .data = drive.chip.memory[rel_addr] },
                    MOS6502.Instruction.DecodeError.EndOfSource => break :draw_instructions,
                    else => return err,
                };
                addr_cursor += len;
                break :brk .{ .instr = decoded };
            }
            break :brk .{ .data = try ctx.computer.read(addr_cursor) };
        };
        const text = switch (decoded) {
            .instr => |instr| std.fmt.bufPrintZ(&buf, "{x:04}: {f}", .{ instr_addr, instr }),
            .data => |data| std.fmt.bufPrintZ(&buf, "{x:04}: 0x{x:02}", .{ instr_addr, data }),
        } catch "err";
        rl.drawTextEx(ctx.font, text, .init(@floatFromInt(x), @floatFromInt(y)), UI.font_size, UI.text_spacing, .green);
    }
}

fn drawMemoryAsCells(computer: *Computer, draw_background: bool) void {
    const memory = computer.modules.get(Computer.RAM);
    const write_events = if (draw_background) brk: {
        var copy: @TypeOf(memory.write_events) = .full;
        break :brk &copy;
    } else &memory.write_events;

    drawMemoryCells(&memory.chip.memory, write_events, .{
        .cols = UI.memory_cell_cols,
        .memory_cols = UI.memory_cell_cols,
        .color_override = if (draw_background) .gray else null,
        // .paged = .{
        //     .active_cell = computer.cpu.registers.pc.toInt(),
        //     .rows_per_page = UI.memory_cell_rows,
        // },
    });
}

fn drawGraphicMemoryAsCells(
    computer: *Computer,
    comptime sub_module_tag: Computer.GPU.SubModuleTag,
    cols: usize,
    memory_cols: usize,
    draw_background: bool,
) void {
    const graphics = computer.modules.get(Computer.GPU);
    const sub_module = graphics.chip.getModule(sub_module_tag);
    var write_events_copy: @TypeOf(sub_module.write_events) = .full;
    const write_events = if (draw_background) &write_events_copy else &sub_module.write_events;

    drawMemoryCells(graphics.chip.tileMap(), write_events, .{
        .cols = cols,
        .memory_cols = memory_cols,
        .color_override = if (draw_background) .gray else null,
    });
}

const DrawMemoryCellsOptions = struct {
    cols: usize,
    memory_cols: usize,
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
    // const cols = options.cols;
    const memory_cols = options.memory_cols;
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

        const display_col = i % memory_cols;
        const display_row = @divFloor(i, memory_cols);
        // const memory_col = i % memory_cols;
        // const memory_row = @divFloor(i, memory_cols);

        if (i >= memory.len) break;

        const byte = memory[i];
        const col_row = @Vector(2, i32){ @intCast(display_col), @intCast(display_row) };
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

fn drawController(ctx: *UIDebugContext) !void {
    const offset_x: f32, const offset_y: f32 = UI.controller_buttons_offset;
    const step = 16;
    const buttons = Byte.fromInt(try ctx.computer.modules.getConst(Controller).chip.read(0));

    const DrawButton = struct {
        pub fn draw(render_buffer: RenderBuffer, button_state: u1, offset: @Vector(2, f32), r: f32) void {
            const color: rl.Color = if (button_state == 1) .yellow else .gray;
            render_buffer.drawEx(offset, r, color);
        }
    };

    const DrawCardinalButtons = struct {
        pub fn draw(render_buffer: RenderBuffer, state: Nibble, offset: @Vector(2, f32)) void {
            const dst = render_buffer.dst;
            DrawButton.draw(render_buffer, state.b0, offset, 0);
            DrawButton.draw(render_buffer, state.b1, offset + @Vector(2, f32){ -step, step + dst.height }, 270);
            DrawButton.draw(render_buffer, state.b2, offset + @Vector(2, f32){ dst.width, step * 2 + dst.height }, 180);
            DrawButton.draw(render_buffer, state.b3, offset + @Vector(2, f32){ step + dst.width, step }, 90);
        }
    };

    DrawCardinalButtons.draw(ctx.render_buffers.directional_button, @as(Nibble, @bitCast(buttons.nibble(0))), .{ offset_x, offset_y });
    DrawCardinalButtons.draw(ctx.render_buffers.button, @as(Nibble, @bitCast(buttons.nibble(1))), .{ offset_x + step * 4, offset_y });
}
