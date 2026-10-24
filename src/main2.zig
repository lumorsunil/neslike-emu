const std = @import("std");
const rl = @import("raylib");

var phase: f32 = 0;
const step: f32 = 440.0 / 44100.0;

fn audioCallback(buffer_any: ?*anyopaque, frames: c_uint) callconv(.c) void {
    const buffer: [*c]f32 = @ptrCast(@alignCast(buffer_any.?));
    for (0..frames) |i| {
        buffer[i] = @sin(phase * std.math.pi * 2);

        phase += step;
        if (phase >= 1) {
            phase -= 1;
        }
    }

    std.log.debug("buffer[0]: {}", .{buffer[0]});
}

pub fn main(init: std.process.Init) !void {
    _ = init;

    rl.initWindow(800, 600, "test");
    defer rl.closeWindow();
    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    // rl.setAudioStreamBufferSizeDefault(735);
    // rl.setAudioStreamBufferSizeDefault(245);
    const stream = try rl.loadAudioStream(44100, 32, 1);
    rl.playAudioStream(stream);
    rl.setAudioStreamCallback(stream, audioCallback);
    rl.setMasterVolume(0.2);
    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        rl.clearBackground(.black);
        rl.endDrawing();
    }
}
