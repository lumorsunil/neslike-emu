pub const MemoryMap = struct {
    min: u16,
    len: u16,

    pub fn init(min: u16, len: u16) @This() {
        return .{ .min = min, .len = len };
    }

    pub fn isMapped(self: @This(), comptime T: type, addr: u16) ?T {
        if (addr >= self.min and addr < @as(u17, self.len) + self.min) {
            return @truncate(addr - self.min);
        }
        return null;
    }

    pub fn slice(self: @This(), source: []u8) []u8 {
        return source[self.min .. self.min + self.len];
    }
};
