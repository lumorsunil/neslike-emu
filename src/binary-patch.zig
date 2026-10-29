const std = @import("std");

pub const BinaryPatch = struct {
    pub fn save(io: std.Io, source: []const u8, modified: []const u8, original_file_path: []const u8) !void {
        var buf: [1024]u8 = undefined;
        var fixed_allocator = std.heap.FixedBufferAllocator.init(&buf);
        const patch_file_path = try std.fmt.allocPrint(fixed_allocator.allocator(), "{s}.patch", .{original_file_path});
        const patch_file = try std.Io.Dir.cwd().createFile(io, patch_file_path, .{});
        defer patch_file.close(io);

        var writer = patch_file.writer(io, &.{});
        try serialize(source, modified, &writer.interface);
    }

    // pub fn save(io: std.Io, binary_patch: *std.Io.Reader, original_file_path: []const u8) !void {
    //     var buf: [1024]u8 = undefined;
    //     var fixed_allocator = std.heap.FixedBufferAllocator.init(&buf);
    //     const patch_file_path = try std.fmt.allocPrint(fixed_allocator.allocator(), "{s}.patch", .{original_file_path});
    //     const patch_file = try std.Io.Dir.cwd().openFile(io, patch_file_path, .{ .mode = .write_only });
    //     defer patch_file.close(io);
    //
    //     var writer = patch_file.writer(io, &.{});
    //     binary_patch.stream(&writer.interface, .unlimited) catch |err| switch (err) {
    //         std.Io.Reader.StreamError.EndOfStream => {},
    //         else => return err,
    //     };
    // }

    pub fn load(io: std.Io, binary_patch: *std.Io.Writer, original_file_path: []const u8) !void {
        var buf: [1024]u8 = undefined;
        var fixed_allocator = std.heap.FixedBufferAllocator.init(&buf);
        const patch_file_path = try std.fmt.allocPrint(fixed_allocator.allocator(), "{s}.patch", .{original_file_path});
        const patch_file = try std.Io.Dir.cwd().openFile(io, patch_file_path, .{ .mode = .read_only });
        defer patch_file.close(io);

        var reader_buffer: [1024]u8 = undefined;
        var reader = patch_file.reader(io, &reader_buffer);
        _ = reader.interface.stream(binary_patch, .unlimited) catch |err| switch (err) {
            std.Io.Reader.StreamError.EndOfStream => {},
            else => return err,
        };
    }

    pub fn serialize(source: []const u8, modified: []const u8, writer: *std.Io.Writer) !void {
        if (source.len != modified.len) {
            std.log.err("source and modified not equal lengths: source: {}, modified: {}", .{ source.len, modified.len });
            @panic("source and modified not equal lengths");
        }
        for (source, modified, 0..) |src, mod, i| {
            if (src != mod) {
                try writer.print("{x:04}={x:02}\n", .{ i, mod });
            }
        }
    }

    pub fn deserialize(modifiable_source: []u8, serialized: []const u8) !void {
        var line_it = std.mem.splitScalar(u8, serialized, '\n');
        while (line_it.next()) |line| {
            if (std.mem.trim(u8, line, "\n\r \t").len == 0) continue;
            var eq_it = std.mem.splitScalar(u8, line, '=');
            const addr = try std.fmt.parseInt(u16, eq_it.next() orelse unreachable, 16);
            const data = try std.fmt.parseInt(u8, eq_it.next() orelse unreachable, 16);
            modifiable_source[addr] = data;
        }
    }
};
