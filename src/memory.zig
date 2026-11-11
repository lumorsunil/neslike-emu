const std = @import("std");

pub fn Memory(comptime label_: []const u8, comptime memory_len_: u16) type {
    return struct {
        memory: [memory_len]u8 = undefined,

        pub const label = label_;

        pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
        pub const memory_len = memory_len_;

        pub fn read(self: @This(), addr: Addr) Error!u8 {
            return self.memory[addr];
        }

        pub fn write(self: *@This(), addr: Addr, data: u8) Error!void {
            self.memory[addr] = data;
        }

        pub const Error = error{};
    };
}
