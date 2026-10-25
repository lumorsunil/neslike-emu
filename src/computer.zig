const std = @import("std");
const MOS6502 = @import("6502.zig").MOS6502;
const Memory = @import("memory.zig").Memory;
const Graphics = @import("graphics.zig").Graphics;
const Controller = @import("controller.zig").Controller;
const Startup = @import("startup.zig").Startup;
const Audio = @import("audio.zig").Audio;
const Drive = @import("drive.zig").Drive;
const Randomizer = @import("randomizer.zig").Randomizer;
const Debug = @import("debug.zig").Debug;
const ModuleCollection = @import("module.zig").ModuleCollection;

pub const Computer = struct {
    cpu: MOS6502 = .init(),
    modules: ModuleCollection(.{
        Memory,
        Graphics,
        Audio,
        Drive,
        Controller,
        Randomizer,
        Startup,
        Debug,
    }) = .init(.{
        .init(0x0000),
        .init(0x0400),
        .init(0x4000),
        .init(0xD000),
        .init(0xF000),
        .init(0xFFFB),
        .init(0xFFFC),
        .init(0xFFFF),
    }),

    pub const fps = 60;
    pub const clock_cycles_per_second = 2_000_000;
    pub const clock_cycles_per_frame = clock_cycles_per_second / fps;

    pub fn step(self: *@This()) Error!void {
        _ = try self.cpu.update();

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

    pub const Error = error{} || MOS6502.Error || Graphics.Error;
};
