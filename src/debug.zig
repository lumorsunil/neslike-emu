const std = @import("std");
const MOS6502 = @import("6502.zig");

pub const Debug = struct {
    is_stop: bool = false,
    cpu: *MOS6502.MOS6502 = undefined,

    pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
    pub const memory_len = 1;

    pub fn write(self: *@This(), _: Addr, data: u8) Error!void {
        std.log.debug("{f}", .{MOS6502.formatCpu(self.cpu, .terminal)});
        if (data == 0) {
            self.is_stop = true;
        }
    }

    pub const Error = error{};
};
