const std = @import("std");

pub const Startup = struct {
    memory: [memory_len]u8 = undefined,

    pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
    pub const memory_len = 2;

    pub fn read(self: @This(), addr: Addr) Error!u8 {
        return self.memory[addr];
    }

    pub const Error = error{};
};
