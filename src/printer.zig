const std = @import("std");

pub const Printer = struct {
    buffer: [Mode.maxSize()]u8 = undefined,
    bytes_written: usize = 0,
    writer: *std.Io.Writer = undefined,
    mode: Mode = .uint8_hex,

    pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
    pub const memory_len = 2;

    pub fn write(self: *@This(), addr: Addr, data: u8) Error!void {
        switch (addr) {
            0 => {
                self.mode = @enumFromInt(data);
                self.bytes_written = 0;
            },
            1 => {
                self.buffer[self.bytes_written] = data;
                self.bytes_written += 1;
                if (self.bytes_written == self.mode.size()) {
                    self.bytes_written = 0;

                    try switch (self.mode) {
                        .uint8_dec => self.writer.print("{}", .{self.buffer[0]}),
                        .uint8_hex => self.writer.print("{x:02}", .{self.buffer[0]}),
                        .uint16_dec => |t| self.writer.print("{}", .{std.mem.readInt(u16, self.buffer[0..comptime t.size()], .little)}),
                        .uint16_hex => |t| self.writer.print("{x:04}", .{std.mem.readInt(u16, self.buffer[0..comptime t.size()], .little)}),
                        .uint24_dec => |t| self.writer.print("{}", .{std.mem.readInt(u24, self.buffer[0..comptime t.size()], .little)}),
                        .uint24_hex => |t| self.writer.print("{x:06}", .{std.mem.readInt(u24, self.buffer[0..comptime t.size()], .little)}),
                        .uint40_dec => |t| self.writer.print("{}", .{std.mem.readInt(u40, self.buffer[0..comptime t.size()], .little)}),
                        .uint40_hex => |t| self.writer.print("{x:06}", .{std.mem.readInt(u40, self.buffer[0..comptime t.size()], .little)}),
                        .ascii => self.writer.print("{c}", .{self.buffer[0]}),
                    };
                }
            },
        }
    }

    pub const Mode = enum(u4) {
        uint8_dec = 0,
        uint8_hex = 1,
        uint16_dec = 2,
        uint16_hex = 3,
        uint24_dec = 4,
        uint24_hex = 5,
        uint40_dec = 6,
        uint40_hex = 7,
        ascii = 8,

        pub fn size(self: @This()) usize {
            return switch (self) {
                .uint8_dec => 1,
                .uint8_hex => 1,
                .uint16_dec => 2,
                .uint16_hex => 2,
                .uint24_dec => 3,
                .uint24_hex => 3,
                .uint40_dec => 5,
                .uint40_hex => 5,
                .ascii => 1,
            };
        }

        pub fn maxSize() usize {
            var max: usize = 0;
            inline for (std.meta.tags(@This())) |tag| {
                if (tag.size() > max) {
                    max = tag.size();
                }
            }
            return max;
        }
    };

    pub const Error = error{} || std.Io.Writer.Error;
};
