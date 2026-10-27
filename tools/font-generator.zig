const std = @import("std");
const rl = @import("raylib");

fn printUsage() void {
    std.log.debug("Usage: zig build generate-font <input-image-file> <output-dasm-file>", .{});
}

const OutputColor = enum(u2) { black, white };

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args;
    var args_it = try args.iterateAllocator(init.gpa);
    args_it.deinit();

    _ = args_it.next();

    const input_file = args_it.next() orelse return printUsage();
    const output_file = args_it.next() orelse return printUsage();

    const image = try rl.loadImage(input_file);
    defer rl.unloadImage(image);

    const tile_size = @Vector(2, i32){ 8, 8 };

    const cols = @divExact(image.width, tile_size[0]);
    const rows = @divExact(image.height, tile_size[1]);

    var allocating_writer: std.Io.Writer.Allocating = .init(init.gpa);
    defer allocating_writer.deinit();

    try allocating_writer.writer.writeAll("import { asm } from \"./asm.js\";\nimport { tile } from \"./utils.js\";\n\nconst font = () => asm`\nfont:\n");

    for (0..@intCast(rows)) |row| {
        for (0..@intCast(cols)) |col| {
            try allocating_writer.writer.writeAll("${tile(`\n");
            for (0..8) |ly| {
                for (0..8) |lx| {
                    const x: i32 = @intCast(col * tile_size[0] + lx);
                    const y: i32 = @intCast(row * tile_size[1] + ly);
                    const c = image.getColor(x, y);
                    const o: OutputColor = if (std.meta.eql(c, .black)) .black else .white;

                    try allocating_writer.writer.print("{}", .{@intFromEnum(o)});
                }
                try allocating_writer.writer.writeByte('\n');
            }
            try allocating_writer.writer.writeAll("`)}\n");
        }
    }

    try allocating_writer.writer.writeAll("`;\n\nexport { font };");

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .data = allocating_writer.written(),
        .sub_path = output_file,
    });
}
