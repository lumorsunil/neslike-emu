const std = @import("std");
const MemoryMap = @import("memory-map.zig").MemoryMap;

pub fn Module(comptime Impl: type) type {
    return struct {
        chip: Impl = .{},
        memory_map: MemoryMap,
        write_events: WriteEvents = .empty,

        pub const WriteEvents = std.StaticBitSet(Impl.memory_len);

        pub fn init(mmap_min: u16) @This() {
            return .{ .memory_map = .init(mmap_min, Impl.memory_len) };
        }

        pub fn isMapped(self: *const @This(), addr: u16) ?Impl.Addr {
            return self.memory_map.isMapped(Impl.Addr, addr);
        }

        pub fn step(self: *@This()) brk: {
            if (std.meta.hasMethod(Impl, "step")) {
                break :brk (@typeInfo(@TypeOf(Impl.step)).@"fn".return_type orelse void);
            } else {
                break :brk void;
            }
        } {
            if (comptime std.meta.hasMethod(Impl, "step")) {
                return self.chip.step();
            }
        }
    };
}

pub fn ModuleCollection(comptime module_impls: anytype) type {
    const Modules = comptime brk: {
        var module_types_: [module_impls.len]type = undefined;
        for (module_impls, 0..) |Impl, i| {
            module_types_[i] = Module(Impl);
        }

        const module_types = module_types_;

        break :brk @Tuple(&module_types);
    };

    return struct {
        modules: Modules,

        pub fn init(modules: Modules) @This() {
            return .{ .modules = modules };
        }

        pub fn get(self: *@This(), comptime T: type) *Module(T) {
            inline for (std.meta.fields(Modules)) |field| {
                if (comptime field.type == Module(T)) {
                    return &@field(self.modules, field.name);
                }
            }

            @compileError("Module type not found: " ++ @typeName(T));
        }

        pub fn getConst(self: @This(), comptime T: type) Module(T) {
            return @constCast(&self).get(T).*;
        }
    };
}
