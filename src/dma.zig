const Computer = @import("computer.zig").Computer;

pub const DirectMemoryAccess = struct {
    computer: *Computer,

    pub fn read(self: @This(), addr: u16) Error!u8 {
        return self.computer.read(addr);
    }

    pub fn write(self: @This(), addr: u16, data: u8) Error!u8 {
        return self.computer.write(addr, data);
    }

    pub const Error = error{} || Computer.Error;
};
