const std = @import("std");
const MOS6502 = @import("6502.zig").MOS6502;
const Instruction = @import("6502.zig").Instruction;
const Memory = @import("memory.zig").Memory;
const Graphics = @import("graphics.zig").Graphics;
const Controller = @import("controller.zig").Controller;
const Startup = @import("startup.zig").Startup;
const Audio = @import("audio.zig").Audio;
const Drive = @import("drive.zig").Drive;
const Randomizer = @import("randomizer.zig").Randomizer;
const Debug = @import("debug.zig").Debug;
const Printer = @import("printer.zig").Printer;
const ModuleCollection = @import("module.zig").ModuleCollection;
const RingBuffer = @import("ring-buffer.zig").RingBuffer;

pub const Computer = struct {
    cpu: MOS6502 = .init(),
    modules: ModuleCollection(.{
        RAM,
        GPU,
        Audio,
        HardDrive,
        CartridgeSlot,
        Controller,
        Printer,
        Randomizer,
        Startup,
        Debug,
    }) = .init(.{
        .init(0x0000), // RAM
        .init(0x0400), // GPU
        .init(0x4000), // Audio
        .init(0xC000), // HardDrive
        .init(0xD000), // CartridgeSlot
        .init(0xF000), // Controller
        .init(0xFFF9), // Printer
        .init(0xFFFB), // Randomizer
        .init(0xFFFC), // Startup
        .init(0xFFFF), // Debug
    }),
    instruction_history: RingBuffer(InstructionEntry, 100) = .{},

    pub const fps = 60;
    pub const clock_cycles_per_second = 2_000_000;
    pub const clock_cycles_per_frame = clock_cycles_per_second / fps;

    pub fn step(self: *@This()) Error!void {
        switch (self.cpu.update() catch |err| {
            std.log.err("{f}", .{self.cpu.formatTerminal()});

            while (self.instruction_history.takeSlice()) |instructions| {
                for (instructions) |instr| {
                    std.log.err("{f}", .{instr});
                }
            }

            std.log.err("instr_addr: {?x:04}", .{self.cpu.instr_addr});
            if (self.cpu.instr_addr) |instr_addr| {
                const first = try self.read(instr_addr);
                const second = try self.read(instr_addr + 1);
                const third = try self.read(instr_addr + 2);
                if (Instruction.decode(&.{ first, second, third })) |t| {
                    const instr, _ = t;
                    std.log.err("{x:04}: {f}", .{ instr_addr, instr });
                } else |err_| {
                    std.log.err("{}: failed to decode: {x:02},{x:02},{x:02}", .{ err_, first, second, third });
                }
            }

            return err;
        }) {
            .execute_instruction => |event| if (event.executed_instr_addr) |addr| {
                const first = try self.read(addr);
                const second = try self.read(addr + 1);
                const third = try self.read(addr + 2);
                const instr, _ = try Instruction.decode(&.{ first, second, third });
                _ = self.instruction_history.append(.{
                    .instruction = instr,
                    .addr = addr,
                }, true);
            },
            else => {},
        }

        var rdy: u1 = 1;

        try self.stepSubModules(&rdy);

        self.cpu.inputs.rdy = rdy;
    }

    pub fn stepFrame(self: *@This()) Error!void {
        inline for (&self.modules.modules) |*module| {
            if (comptime std.meta.hasMethod(@TypeOf(module.chip), "stepFrame")) {
                try module.chip.stepFrame();
            }
        }
    }

    fn stepSubModules(self: *@This(), rdy: *u1) Error!void {
        inline for (&self.modules.modules) |*module| {
            read_write_brk: {
                const has_read = comptime std.meta.hasMethod(@TypeOf(module.chip), "read");
                const has_write = comptime std.meta.hasMethod(@TypeOf(module.chip), "write");

                if (comptime !has_write and !has_read) break :read_write_brk;

                switch (self.cpu.read_write) {
                    .read => if (comptime has_read) {
                        if (module.isMapped(self.cpu.address_bus.toInt())) |rel_addr| {
                            self.cpu.data_bus = .fromInt(try module.chip.read(rel_addr));
                        }
                    },
                    .write => if (comptime has_write) {
                        if (module.isMapped(self.cpu.address_bus.toInt())) |rel_addr| {
                            module.write_events.set(rel_addr);
                            try module.chip.write(rel_addr, self.cpu.data_bus.toInt());
                        }
                    },
                }
            }

            if (comptime std.meta.hasMethod(@TypeOf(module.chip), "step")) {
                try module.chip.step();
            }

            if (comptime @hasField(@TypeOf(module.chip), "rdy")) {
                rdy.* &= module.chip.rdy;
            }
        }
    }

    pub fn read(self: *@This(), addr: u16) Error!u8 {
        inline for (&self.modules.modules) |*module| {
            const has_read = comptime std.meta.hasMethod(@TypeOf(module.chip), "read");

            if (!has_read) {
                std.log.err("invalid read addr: 0x{x:04}", .{addr});
                return Error.InvalidReadAddr;
            }

            if (module.isMapped(addr)) |rel_addr| {
                return try module.chip.read(rel_addr);
            }
        }
    }

    pub fn write(self: *@This(), addr: u16, data: u8) Error!void {
        inline for (&self.modules.modules) |*module| {
            const has_write = comptime std.meta.hasMethod(@TypeOf(module.chip), "write");

            if (!has_write) return Error.InvalidWriteAddr;

            if (module.isMapped(addr)) |rel_addr| {
                return try module.chip.write(rel_addr, data);
            }
        }
    }

    pub const RAM = Memory("ram", 0x0400);
    pub const GPU = Graphics;
    pub const HardDrive = Drive("hard-drive", 0x1000);
    pub const CartridgeSlot = Drive("cartridge", 0x2000);

    const InstructionEntry = struct {
        addr: u16,
        instruction: Instruction,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{x:04}: {f}", .{ self.addr, self.instruction });
        }
    };

    pub const Error = error{
        InvalidReadAddr,
    } || MOS6502.Error || Instruction.DecodeError || Graphics.Error || Printer.Error;
};
