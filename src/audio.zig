const std = @import("std");
const ifc = @import("interface.zig");
const rl = @import("raylib");

pub const Audio = struct {
    memory: [memory_len]u8 = undefined,
    audio_stream: rl.AudioStream = undefined,
    prev_sample: f32 = 0,
    filtered_sample: f32 = 0,
    noise_lut: [4096]u8 = undefined,

    fn getPackedStructByteSize(comptime T: type) usize {
        return @typeInfo(@typeInfo(T).@"struct".backing_integer.?).int.bits / 8;
    }

    const ADSR = packed struct(u8) {
        attack: u8,
    };
    const adsr_size = getPackedStructByteSize(ADSR);

    const SquareWave = packed struct(u104) {
        duty_cycle: u8 = duty_cycle_50,
        volume: u4 = 0,
        _: u4 = 0,
        phase: f32 = 0,
        phase_step: f32 = 440.0 / sample_rate * 8.0,
        frequency: packed struct(u24) {
            int_lo: u8,
            int_hi: u8,
            fraction: u8,
        } = .{
            .int_lo = 0xb8,
            .int_hi = 0x01,
            .fraction = 0,
        },

        fn tick(self: *align(1) @This()) f32 {
            const duty_cycle_out: f32 = @floatFromInt(self.duty_cycle & 1);
            const result = duty_cycle_out * @as(f32, @floatFromInt(self.volume));

            self.phase += self.phase_step;
            if (self.phase >= 1) {
                self.phase -= 1;

                self.duty_cycle, const carry = @shlWithOverflow(self.duty_cycle, 1);
                self.duty_cycle |= carry;
            }

            return result;
        }

        fn setFrequency(self: *align(1) @This()) void {
            const int: u16 = @as(u16, self.frequency.int_hi) << 8 | self.frequency.int_lo;
            const frequency = @as(f32, @floatFromInt(int)) + @as(f32, @floatFromInt(self.frequency.fraction)) / 100;
            self.phase_step = (frequency / sample_rate) * 8;
            // self.phase = 0;
        }
    };
    const square_wave_size = getPackedStructByteSize(SquareWave);

    const TriangleWave = packed struct(u104) {
        sequence: u5 = sequence_start,
        _: u3 = 0,
        volume: u4 = 0,
        __: u4 = 0,
        phase: f32 = 0,
        phase_step: f32 = 220.0 / sample_rate * 32.0,
        frequency: packed struct(u24) {
            int_lo: u8,
            int_hi: u8,
            fraction: u8,
        } = .{
            .int_lo = 0xdc,
            .int_hi = 0x00,
            .fraction = 0,
        },

        const sequence_start: u5 = 8;

        fn tick(self: *align(1) @This()) f32 {
            const seq_out: f32 = @floatFromInt(if (self.sequence > 15) 31 - self.sequence else self.sequence);
            const vol_ratio = @as(f32, @floatFromInt(self.volume)) / 15.0;
            const result = if (vol_ratio > 0) seq_out * vol_ratio else seq_out;

            self.phase += self.phase_step;
            if (self.phase >= 1) {
                self.phase -= 1;
                if (self.volume > 0) {
                    self.sequence +%= 1;
                }
            }

            return result;
        }

        fn setVolume(self: *align(1) @This(), prev_data: u8) void {
            const prev_volume: u4 = @truncate(prev_data);

            if (prev_volume == 0 and self.volume > 0) {
                self.phase = 0;
                self.sequence = sequence_start;
            }
        }

        fn setFrequency(self: *align(1) @This()) void {
            const int: u16 = @as(u16, self.frequency.int_hi) << 8 | self.frequency.int_lo;
            const frequency = @as(f32, @floatFromInt(int)) + @as(f32, @floatFromInt(self.frequency.fraction)) / 100;
            self.phase_step = (frequency / sample_rate) * 32;
            // self.phase = 0;
        }
    };
    const triangle_wave_size = getPackedStructByteSize(TriangleWave);

    const Noise = packed struct(u112) {
        volume: u4 = 0x0,
        _: u4 = 0,
        counter: u15 = 0,
        mode: u1 = 0,
        phase: f32 = 0,
        phase_step: f32 = 4000.0 / sample_rate,
        frequency: packed struct(u24) {
            int_lo: u8,
            int_hi: u8,
            fraction: u8,
        } = .{
            .int_lo = 0xdc,
            .int_hi = 0x00,
            .fraction = 0,
        },

        fn tick(self: *align(1) @This(), audio: Audio) f32 {
            const i = @divFloor(self.counter, 8);
            const n_byte = audio.noise_lut[if (self.mode == 1) (i + 1024) % 32 else i];
            const n_bit: u1 = @truncate(n_byte >> @as(u3, @truncate(self.counter % 8)));
            const result = n_bit * self.volume;

            self.phase += self.phase_step;
            if (self.phase >= 1) {
                self.phase -= 1;
                self.counter +%= 1;
            }

            return result;
        }

        fn setFrequency(self: *align(1) @This()) void {
            const int: u16 = @as(u16, self.frequency.int_hi) << 8 | self.frequency.int_lo;
            const frequency = @as(f32, @floatFromInt(int)) + @as(f32, @floatFromInt(self.frequency.fraction)) / 100;
            self.phase_step = frequency / sample_rate;
            // self.phase = 0;
        }
    };
    const noise_size = getPackedStructByteSize(Noise);

    pub const Addr = std.math.IntFittingRange(0, memory_len - 1);
    pub const memory_len = 2 * square_wave_size + triangle_wave_size + noise_size;

    pub const audio_buffer_size = 735;
    pub const sample_rate = 44100.0;
    // pub const sample_rate = 2_000_000.0;
    var ring_buffer: [ring_buffer_size]f32 = undefined;
    var ring_buffer_read: usize = 0;
    var ring_buffer_write: usize = 0;
    const ring_buffer_size = 4096;
    const alpha = 0.985;
    const duty_cycle_50: u8 = 0b11110000;

    const square_wave_1_start = 0;
    const square_wave_1_end = square_wave_1_start + square_wave_size;
    const square_wave_2_start = square_wave_1_end;
    const square_wave_2_end = square_wave_2_start + square_wave_size;
    const triangle_wave_start = square_wave_2_end;
    const triangle_wave_end = triangle_wave_start + triangle_wave_size;
    const noise_start = triangle_wave_end;
    const noise_end = noise_start + noise_size;

    pub fn initMemory(self: *@This()) void {
        self.getSquareWave1().* = .{};
        self.getSquareWave2().* = .{};
        self.getTriangleWave().* = .{};
        self.getNoise().* = .{};
    }

    fn getSquareWave1(self: *@This()) *align(1) SquareWave {
        return std.mem.bytesAsValue(SquareWave, self.memory[square_wave_1_start..square_wave_1_end]);
    }

    fn getSquareWave2(self: *@This()) *align(1) SquareWave {
        return std.mem.bytesAsValue(SquareWave, self.memory[square_wave_2_start..square_wave_2_end]);
    }

    fn getTriangleWave(self: *@This()) *align(1) TriangleWave {
        return std.mem.bytesAsValue(TriangleWave, self.memory[triangle_wave_start..triangle_wave_end]);
    }

    fn getNoise(self: *@This()) *align(1) Noise {
        return std.mem.bytesAsValue(Noise, self.memory[noise_start..noise_end]);
    }

    pub fn stepFrame(_: *@This()) Error!void {
        const samples_to_generate: usize = @ceil(rl.getFrameTime() * sample_rate);
        generateAudioDataToRingBuffer(samples_to_generate);
    }

    pub fn read(self: @This(), addr: Addr) Error!u8 {
        return self.memory[addr];
    }

    pub fn write(self: *@This(), addr: Addr, data: u8) Error!void {
        const freq_len = 3;

        const prev_data = self.memory[addr];
        self.memory[addr] = data;

        if (addr >= square_wave_1_start + @offsetOf(SquareWave, "frequency") and addr <= square_wave_1_start + @offsetOf(SquareWave, "frequency") + freq_len) {
            const square_wave_1 = self.getSquareWave1();
            square_wave_1.setFrequency();
        } else if (addr >= square_wave_2_start + @offsetOf(SquareWave, "frequency") and addr <= square_wave_2_start + @offsetOf(SquareWave, "frequency") + freq_len) {
            const square_wave_2 = self.getSquareWave2();
            square_wave_2.setFrequency();
        } else if (addr >= triangle_wave_start + @offsetOf(TriangleWave, "frequency") and addr <= triangle_wave_start + @offsetOf(TriangleWave, "frequency") + freq_len) {
            const triangle_wave = self.getTriangleWave();
            triangle_wave.setFrequency();
        } else if (addr >= triangle_wave_start + @offsetOf(TriangleWave, "volume") and addr <= triangle_wave_start + @offsetOf(TriangleWave, "volume") + 1) {
            const triangle_wave = self.getTriangleWave();
            triangle_wave.setVolume(prev_data);
        } else if (addr >= noise_start + @offsetOf(Noise, "frequency") and addr <= noise_start + @offsetOf(Noise, "frequency") + freq_len) {
            const noise = self.getNoise();
            noise.setFrequency();
        }
    }

    pub var self_: *@This() = undefined;

    pub fn audioStreamCallback(buffer_any: ?*anyopaque, frames: c_uint) callconv(.c) void {
        // std.log.debug("frames: {}", .{frames});
        const buffer: [*c]f32 = @ptrCast(@alignCast(buffer_any.?));

        for (0..frames) |i| {
            if (ring_buffer_read != ring_buffer_write) {
                ring_buffer_read += 1;
                ring_buffer_read %= ring_buffer_size;
                buffer[i] = ring_buffer[ring_buffer_read];
            } else {
                // TODO: fix this? (seems to work though)
                buffer[i] = 0;
                // generateAudioData(buffer[i..frames]);
                break;
            }
        }
    }

    fn generateAudioDataToRingBuffer(frames: usize) void {
        const space = if (ring_buffer_read <= ring_buffer_write) (ring_buffer_size - ring_buffer_write - 1 + ring_buffer_read) else ring_buffer_read - ring_buffer_write - 1;
        const actual_frames = @min(frames, space);
        ring_buffer_write += 1;
        ring_buffer_write %= ring_buffer_size;
        const end_len = @min(ring_buffer.len - ring_buffer_write, actual_frames);
        const end = ring_buffer_write + end_len;
        const ring_buffer_end = ring_buffer[ring_buffer_write..end];
        const rest = actual_frames - end_len;
        const ring_buffer_start = ring_buffer[0..rest];

        generateAudioData(ring_buffer_end);
        generateAudioData(ring_buffer_start);

        ring_buffer_write += actual_frames - 1;
        ring_buffer_write %= ring_buffer_size;
    }

    fn generateAudioData(buffer: []f32) void {
        const square_wave_1 = self_.getSquareWave1();
        const square_wave_2 = self_.getSquareWave2();
        const triangle_wave = self_.getTriangleWave();
        const noise = self_.getNoise();

        const square_wave_1_weight = 0.5;
        const square_wave_2_weight = 0.5;
        const triangle_wave_weight = 1.0;
        const noise_weight = 0.5;

        for (buffer) |*b| {
            const square_wave_1_out = ((square_wave_1.tick() / 15.0) * 2.0 - 1.0) * square_wave_1_weight;
            const square_wave_2_out = ((square_wave_2.tick() / 15.0) * 2.0 - 1.0) * square_wave_2_weight;
            const triangle_wave_out = ((triangle_wave.tick() / 15.0) * 2.0 - 1.0) * triangle_wave_weight;
            const noise_out = ((noise.tick(self_.*) / 15.0) * 2.0 - 1.0) * noise_weight;

            const raw_sample = (square_wave_1_out + square_wave_2_out + triangle_wave_out + noise_out) / 4.0;

            // NES-stuff
            // const squares = 95.88 / ((8128.0 / (square_wave_1.tick() + square_wave_2.tick())) + 100.0);
            // const tnd = 159.79 / ((100.0 / (triangle_wave.tick() / 8227.0 + noise.tick() / 12241.0)) + 1.0);
            // const raw_sample = squares + tnd;

            self_.filtered_sample = alpha * (self_.filtered_sample + raw_sample - self_.prev_sample);
            self_.prev_sample = raw_sample;

            b.* = self_.filtered_sample * 2.0;
        }
    }

    pub const Error = error{};
};
