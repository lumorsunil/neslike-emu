const std = @import("std");
const ifc = @import("interface.zig");
const Byte = ifc.Byte;
const rl = @import("raylib");

pub const Controller = struct {
    // memory: [memory_len]u8 = undefined,

    pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
    pub const memory_len = n_buttons;

    const n_buttons = std.meta.tags(Button).len;
    const Button = enum {
        down_wasd_ijkl,
        pressed_wasd_ijkl,
    };

    pub fn read(_: @This(), addr: Addr) Error!u8 {
        const button: Button = @enumFromInt(addr);
        return switch (button) {
            .down_wasd_ijkl => (Byte{
                .b0 = @intFromBool(rl.isKeyDown(.w) or rl.isGamepadButtonDown(0, .left_face_up)),
                .b1 = @intFromBool(rl.isKeyDown(.a) or rl.isGamepadButtonDown(0, .left_face_left)),
                .b2 = @intFromBool(rl.isKeyDown(.s) or rl.isGamepadButtonDown(0, .left_face_down)),
                .b3 = @intFromBool(rl.isKeyDown(.d) or rl.isGamepadButtonDown(0, .left_face_right)),
                .b4 = @intFromBool(rl.isKeyDown(.i) or rl.isGamepadButtonDown(0, .right_face_up)),
                .b5 = @intFromBool(rl.isKeyDown(.j) or rl.isGamepadButtonDown(0, .right_face_left)),
                .b6 = @intFromBool(rl.isKeyDown(.k) or rl.isGamepadButtonDown(0, .right_face_down)),
                .b7 = @intFromBool(rl.isKeyDown(.l) or rl.isGamepadButtonDown(0, .right_face_right)),
            }).toInt(),
            .pressed_wasd_ijkl => (Byte{
                .b0 = @intFromBool(rl.isKeyPressed(.w) or rl.isGamepadButtonPressed(0, .left_face_up)),
                .b1 = @intFromBool(rl.isKeyPressed(.a) or rl.isGamepadButtonPressed(0, .left_face_left)),
                .b2 = @intFromBool(rl.isKeyPressed(.s) or rl.isGamepadButtonPressed(0, .left_face_down)),
                .b3 = @intFromBool(rl.isKeyPressed(.d) or rl.isGamepadButtonPressed(0, .left_face_right)),
                .b4 = @intFromBool(rl.isKeyPressed(.i) or rl.isGamepadButtonPressed(0, .right_face_up)),
                .b5 = @intFromBool(rl.isKeyPressed(.j) or rl.isGamepadButtonPressed(0, .right_face_left)),
                .b6 = @intFromBool(rl.isKeyPressed(.k) or rl.isGamepadButtonPressed(0, .right_face_down)),
                .b7 = @intFromBool(rl.isKeyPressed(.l) or rl.isGamepadButtonPressed(0, .right_face_right)),
            }).toInt(),
        };
    }

    pub const Error = error{};
};
