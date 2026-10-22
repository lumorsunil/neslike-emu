const std = @import("std");

pub const Drive = struct {
    memory: [memory_len]u8 = undefined,

    pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
    pub const memory_len = 1024;

    pub fn read(self: @This(), addr: Addr) Error!u8 {
        return self.memory[addr];
    }

    pub fn write(self: *@This(), addr: Addr, data: u8) Error!void {
        self.memory[addr] = data;
    }

    pub const Error = error{};
};
