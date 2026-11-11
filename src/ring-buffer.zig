const std = @import("std");

pub fn RingBuffer(comptime T: type, comptime size_: usize) type {
    return struct {
        buffer: [size]T = undefined,
        read: SizeInt = 0,
        write: SizeInt = 0,

        pub const SizeInt = std.math.IntFittingRange(0, size_);
        pub const size: SizeInt = size_;

        const Self = @This();

        pub fn capacity(self: @This()) SizeInt {
            return if (self.read <= self.write) (size - self.write - 1 + self.read) else self.read - self.write - 1;
        }

        pub fn take(self: *@This()) ?T {
            if (self.read == self.write) return null;

            self.read += 1;
            self.read %= size;

            return self.buffer[self.read];
        }

        pub fn takeSlice(self: *@This()) ?[]T {
            if (self.read == self.write) return null;

            const len = if (self.read < self.write)
                self.write - self.read
            else
                size - self.read;

            const start = self.read;
            const end = self.read + len;

            self.read += len;
            self.read %= size;

            return self.buffer[start..end];
        }

        /// Returns true if successful
        pub fn append(self: *@This(), item: T, overwrite_mode: bool) bool {
            return self.appendSlice(&.{item}, overwrite_mode) == 1;
        }

        pub const WriteableIterator = struct {
            buffers: [2][]T,
            actual_fill_size: SizeInt,
            index: ?u1 = 0,

            pub fn init(ring_buffer: *Self, fill_size: SizeInt, overwrite_mode: bool) @This() {
                const actual_fill_size = if (overwrite_mode) fill_size else @min(fill_size, ring_buffer.capacity());

                ring_buffer.write += 1;
                ring_buffer.write %= size;

                const end_len = @min(size - ring_buffer.write, actual_fill_size);
                const end = ring_buffer.write + end_len;

                if (overwrite_mode and ring_buffer.read >= ring_buffer.write and ring_buffer.read <= end) {
                    ring_buffer.read = end % size;
                }

                const buffer_end = ring_buffer.buffer[ring_buffer.write..end];
                const rest = actual_fill_size - end_len;
                const buffer_start = ring_buffer.buffer[0..rest];

                ring_buffer.write += actual_fill_size - 1;
                ring_buffer.write %= size;

                if (overwrite_mode and ring_buffer.read <= ring_buffer.write) {
                    ring_buffer.read = ring_buffer.write + 1;
                }

                return .{
                    .buffers = .{ buffer_end, buffer_start },
                    .actual_fill_size = actual_fill_size,
                };
            }

            pub fn next(self: *@This()) ?[]T {
                const index = self.index orelse return null;

                defer self.index = if (index == 0) 1 else null;

                return self.buffers[index];
            }
        };

        pub fn writeableIterator(self: *@This(), write_size: SizeInt, overwrite_mode: bool) WriteableIterator {
            return .init(self, write_size, overwrite_mode);
        }

        /// Returns number of items successfully appended
        pub fn appendSlice(self: *@This(), slice: []const T, overwrite_mode: bool) SizeInt {
            var slice_index: SizeInt = 0;

            var it = self.writeableIterator(@intCast(slice.len), overwrite_mode);
            while (it.next()) |buffer| {
                @memcpy(buffer, slice[slice_index .. slice_index + buffer.len]);
                slice_index += @intCast(buffer.len);
            }

            return it.actual_fill_size;
        }
    };
}
