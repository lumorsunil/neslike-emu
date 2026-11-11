const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const rl = @import("raylib");
const Computer = @import("computer.zig").Computer;
const Startup = @import("startup.zig").Startup;
const Audio = @import("audio.zig").Audio;
const Randomizer = @import("randomizer.zig").Randomizer;
const Printer = @import("printer.zig").Printer;
const Debug = @import("debug.zig").Debug;
const UI = @import("ui.zig");
const BinaryPatch = @import("binary-patch.zig").BinaryPatch;
const UIDebugContext = @import("ui-debug.zig").UIDebugContext;
const formatDate = @import("date.zig").formatDate;

const input_file_path = "test.bin";
const input_hard_drive_path = "drive.bin";
const printer_file_path = "printer.txt";

const MainContext = struct {
    file: []const u8,
    binary_patch: []const u8,
    hard_drive: []const u8,
    printer_writer: *std.Io.Writer,
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

    ui_debug: UIDebugContext,
};

pub fn main(init: std.process.Init) !void {
    const printer_file = try std.Io.Dir.cwd().createFile(init.io, printer_file_path, .{
        .truncate = false,
        .read = true,
    });
    defer printer_file.close(init.io);
    const printer_file_len = try printer_file.length(init.io);
    var printer_file_writer = printer_file.writer(init.io, &.{});
    try printer_file_writer.seekTo(printer_file_len);
    const printer_writer = &printer_file_writer.interface;

    if (printer_file_len > 4) {
        try printer_writer.writeAll("\n\n");
    }

    const now = std.Io.Timestamp.now(init.io, .real);
    try printer_writer.print("{f}:\n\n", .{std.fmt.Alt(@TypeOf(now), formatDate){ .data = now }});

    var ctx: MainContext = undefined;
    ctx.printer_writer = printer_writer;
    try initEmu(init.io, init.gpa, &ctx);
    defer deinitEmu(init.gpa, &ctx);

    while (!rl.windowShouldClose()) {
        try loop(&ctx);
    }

    const cartridge_source = ctx.file;
    const cartridge_modified = ctx.computer.modules.get(Computer.CartridgeSlot).chip.memory[0..cartridge_source.len];
    try BinaryPatch.save(init.io, cartridge_source, cartridge_modified, input_file_path);

    const hard_drive_modified = &ctx.computer.modules.get(Computer.HardDrive).chip.memory;
    try std.Io.Dir.cwd().writeFile(init.io, .{ .flags = .{}, .sub_path = input_hard_drive_path, .data = hard_drive_modified });
}

fn initEmu(io: std.Io, allocator: Allocator, ctx: *MainContext) !void {
    rl.initWindow(UI.screen_size[0], UI.screen_size[1], "Core Killer");
    rl.initAudioDevice();
    rl.setWindowFocused();
    rl.setWindowPosition(24, 24);
    // rl.setTargetFPS(60 * 2);

    var binary_patch_allocating_writer = std.Io.Writer.Allocating.init(allocator);
    errdefer binary_patch_allocating_writer.deinit();

    BinaryPatch.load(io, &binary_patch_allocating_writer.writer, input_file_path) catch |err| switch (err) {
        std.Io.File.OpenError.FileNotFound => {},
        else => return err,
    };

    const file = try std.Io.Dir.cwd().readFileAlloc(io, input_file_path, allocator, .unlimited);
    errdefer allocator.free(file);

    const hard_drive = std.Io.Dir.cwd().readFileAlloc(io, input_hard_drive_path, allocator, .unlimited) catch |err| switch (err) {
        std.Io.File.OpenError.FileNotFound => &.{},
        else => return err,
    };
    errdefer allocator.free(hard_drive);

    ctx.* = MainContext{
        .random = std.Random.IoSource{ .io = io },
        .file = file,
        .binary_patch = try binary_patch_allocating_writer.toOwnedSlice(),
        .hard_drive = hard_drive,
        .printer_writer = ctx.printer_writer,
        .ui_debug = .{
            .computer = &ctx.computer,
            .render_buffers = undefined,
            .is_continuing = false,
            .is_fullscreen = true,
            .font = try rl.loadFont("Ac437_IBM_VGA_8x14.ttf"),
        },
    };

    initStartupChip(ctx);
    initMemoryChip(ctx);
    initHardDriveChip(ctx);
    try initCartridgeChip(ctx);
    initRandomizerChip(ctx);
    initPrinterChip(ctx);
    try initGraphicsChip(ctx);
    try initAudio(ctx);
    initDebugChip(ctx);

    try ctx.ui_debug.init();
}

fn deinitEmu(allocator: Allocator, ctx: *MainContext) void {
    allocator.free(ctx.file);
    allocator.free(ctx.binary_patch);
    allocator.free(ctx.hard_drive);
    rl.closeWindow();
    rl.closeAudioDevice();
}

fn restartComputer(ctx: *MainContext) !void {
    restartCpuChip(ctx);
    restartStartupChip(ctx);
    restartMemoryChip(ctx);
    restartHardDriveChip(ctx);
    try restartCartridgeChip(ctx);
    restartRandomizerChip(ctx);
    restartGraphicsChip(ctx);
    restartAudio(ctx);
    restartDebugChip(ctx);

    ctx.ui_debug.restart();
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
    ctx.random.interface().bytes(&ctx.computer.modules.get(Computer.RAM).chip.memory);
}

fn initHardDriveChip(ctx: *MainContext) void {
    restartHardDriveChip(ctx);
}

fn restartHardDriveChip(_: *MainContext) void {
    // const drive_memory = ctx.computer.modules.get(Computer.HardDrive).chip.memory[0..ctx.hard_drive.len];
    // @memcpy(drive_memory, ctx.hard_drive);
}

fn initCartridgeChip(ctx: *MainContext) !void {
    try restartCartridgeChip(ctx);
}

fn restartCartridgeChip(ctx: *MainContext) !void {
    const drive_memory = ctx.computer.modules.get(Computer.CartridgeSlot).chip.memory[0..ctx.file.len];
    @memcpy(drive_memory, ctx.file);
    try BinaryPatch.deserialize(drive_memory, ctx.binary_patch);
}

fn initRandomizerChip(ctx: *MainContext) void {
    restartRandomizerChip(ctx);
}

fn restartRandomizerChip(ctx: *MainContext) void {
    ctx.computer.modules.get(Randomizer).chip.random = .init(ctx.random.interface().int(u64));
}

fn initPrinterChip(ctx: *MainContext) void {
    restartPrinterChip(ctx);
}

fn restartPrinterChip(ctx: *MainContext) void {
    ctx.computer.modules.get(Printer).chip = .{
        .writer = ctx.printer_writer,
    };
}

fn initGraphicsChip(ctx: *MainContext) !void {
    const graphics = ctx.computer.modules.get(Computer.GPU);

    graphics.chip.dma = .{ .computer = &ctx.computer };
    graphics.chip.screen_buffer = try rl.loadRenderTexture(256, 256);
    graphics.chip.background_layer_buffer = try rl.loadRenderTexture(256 * 2, 256 * 2);

    restartGraphicsChip(ctx);
}

fn restartGraphicsChip(ctx: *MainContext) void {
    const graphics = ctx.computer.modules.get(Computer.GPU);
    ctx.random.interface().bytes(&graphics.chip.memory);

    drawRandomPixels(ctx, graphics.chip.screen_buffer);
    drawRandomPixels(ctx, graphics.chip.background_layer_buffer);

    graphics.chip.memory[0x1520] = 0x20;
    graphics.chip.memory[0x1521] = 0x09;
    graphics.chip.memory[0x1522] = 0x20;
    graphics.chip.memory[0x1523] = 0x19;
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

fn loop(ctx: *MainContext) !void {
    ctx.time.begin();
    defer ctx.time.end();

    switch (try ctx.ui_debug.update()) {
        .cont => {},
        .restart => {
            try restartComputer(ctx);
            rl.beginDrawing();
            rl.endDrawing();
            return;
        },
    }

    rl.beginDrawing();
    rl.clearBackground(.black);

    try ctx.ui_debug.draw();

    const graphics = ctx.computer.modules.get(Computer.GPU);
    const screen_scale: f32 = if (ctx.ui_debug.is_fullscreen) 4 else 2;
    const screen_dst = rl.Rectangle.init(UI.screen_size[0] - 256 * screen_scale, 0, 256 * screen_scale, 256 * screen_scale);
    graphics.chip.drawScreen(screen_dst);

    rl.drawFPS(5, UI.screen_size[1] - 20);

    rl.endDrawing();
}

test {
    std.testing.refAllDecls(@This());
}
