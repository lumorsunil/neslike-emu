const std = @import("std");

pub const Randomizer = struct {
    random: std.Random.Xoshiro256 = undefined,

    pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
    pub const memory_len = 1;

    pub fn read(self: *@This(), _: Addr) Error!u8 {
        return self.random.random().int(u8);
    }

    pub fn write(self: *@This(), _: Addr, data: u8) Error!void {
        self.random = .init(data);
    }

    pub const Error = error{};
};
