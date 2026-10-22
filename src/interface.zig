const std = @import("std");

pub const SevenBits = packed struct(u7) {
    b0: u1 = 0,
    b1: u1 = 0,
    b2: u1 = 0,
    b3: u1 = 0,
    b4: u1 = 0,
    b5: u1 = 0,
    b6: u1 = 0,

    pub const zero = @This(){};

    pub fn fromInt(int: u7) @This() {
        return @bitCast(int);
    }

    pub fn toInt(self: @This()) u7 {
        return @bitCast(self);
    }

    pub fn setFromInt(self: *@This(), int: u7) void {
        self.* = .fromInt(int);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{x:02}", .{self.toInt()});
    }
};

pub const Byte = packed struct(u8) {
    b0: u1 = 0,
    b1: u1 = 0,
    b2: u1 = 0,
    b3: u1 = 0,
    b4: u1 = 0,
    b5: u1 = 0,
    b6: u1 = 0,
    b7: u1 = 0,

    pub const zero = @This(){};

    pub fn fromInt(int: u8) @This() {
        return @bitCast(int);
    }

    pub fn fromNibbles(lo: u4, hi: u4) @This() {
        return @as(u8, lo) | (@as(u8, hi) << 4);
    }

    pub const ReduceOp = enum { Or, And, Nor };

    pub fn reduce(self: @This(), comptime op: ReduceOp) u1 {
        return @intFromBool(switch (comptime op) {
            .Or => self.toInt() != 0,
            .Nor => self.toInt() == 0,
            .And => self.toInt() == 0xff,
        });
    }

    pub fn toInt(self: @This()) u8 {
        return @bitCast(self);
    }

    pub fn nibble(self: @This(), nibble_: u1) u4 {
        return @truncate(self.toInt() >> (@as(u3, nibble_) * 4));
    }

    pub fn toIntPtr(self: *@This()) *u8 {
        return @ptrCast(self);
    }

    pub fn setFromInt(self: *@This(), int: u8) void {
        self.* = .fromInt(int);
    }

    pub fn setBit(self: *@This(), bit: u3, value: u1) void {
        const d = self.toInt();
        const s: u8 = @as(u8, value) << bit;
        const r = (d & ~(@as(u8, 1) << bit)) | s;

        self.* = .fromInt(r);
    }

    pub fn setNibble(self: *@This(), nibble_: u1, value: u4) void {
        switch (nibble_) {
            0 => self.setFromInt((self.toInt() & 0xF0) | value),
            1 => self.setFromInt((self.toInt() & 0x0F) | (@as(u8, value) << 4)),
        }
    }

    pub fn getBit(self: @This(), bit: u3) u1 {
        return @truncate(self.toInt() >> bit);
    }

    pub fn add(self: @This(), other: @This()) @This() {
        return .fromInt(self.toInt() +% other.toInt());
    }

    pub fn addWithOverflow(self: @This(), other: @This()) struct { @This(), u1 } {
        const result, const carry = @addWithOverflow(self.toInt(), other.toInt());
        return .{ .fromInt(result), carry };
    }

    pub fn sub(self: @This(), other: @This()) @This() {
        return .fromInt(self.toInt() -% other.toInt());
    }

    pub fn subWithOverflow(self: @This(), other: @This()) struct { @This(), u1 } {
        const result, const carry = @subWithOverflow(self.toInt(), other.toInt());
        return .{ .fromInt(result), carry };
    }

    pub fn inc(self: *@This()) void {
        self.* = .fromInt(self.toInt() +% 1);
    }

    pub fn dec(self: *@This()) void {
        self.* = .fromInt(self.toInt() -% 1);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{x:02}", .{self.toInt()});
    }
};

pub const Word = packed struct(u16) {
    lo: Byte = .zero,
    hi: Byte = .zero,

    pub const zero = @This(){};

    pub fn fromInt(int: u16) @This() {
        return @bitCast(int);
    }

    pub fn fromString(s: []const u8) !@This() {
        return @bitCast(try std.fmt.parseInt(u16, s, 16));
    }

    pub fn toInt(self: @This()) u16 {
        return @bitCast(self);
    }

    pub fn inc(self: *@This()) void {
        self.* = .fromInt(self.toInt() +% 1);
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}{f}", .{ self.hi, self.lo });
    }
};

pub const ReadWrite = enum(u1) {
    read = 1,
    write = 0,
};
