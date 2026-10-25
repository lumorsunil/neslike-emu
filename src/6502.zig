const std = @import("std");
const ifc = @import("interface.zig");
const Byte = ifc.Byte;
const Word = ifc.Word;
const ReadWrite = ifc.ReadWrite;

comptime {
    @setEvalBranchQuota(100000);
}

// TODO: **ONLY FOR 6502, NOT FOR 6507 (atari2600)** irq, nmi and res inputs need to tritger interrups:
//    Interrupt Request (IRQ)
//     This TTL level input requests that an interrupt sequence
//     begin within the microprocessor. The microprocessor will
//     complete the current instruction being executed before recognizing the request. At the time, the interrupt mask bit in
//     the Status Code Register will be examined. If the interrupt
//     mask flag is not set, the microprocessor will begin an interrupt sequence. The Program Counter and Processor Status
//     Register are stored in the stack. The microprocessor will
//     then set the interrupt mask flag high so that no futher interrupts may occur. At the end of this cycle, the program
//     counter low will be loaded from address FFFE, and program
//     counter high from location FFFF, therefore transferring program control to the memory vector located at these
//     addresses. The RDY signal must be in the high state for any
//     interrupt to be recognized. A 3K external resistor should
//     be used for proper wire-OR operation.
//    Non-Maskable Interrupt (NMI)
//     SY6500
//     A negative going transition on this input requests that a
//     non-maskable interrupt sequence be generated within the
//     microprocessor.
//     NMI is an unconditional interrupt. Following completion of
//     the current instruction, the sequence of operations defined
//     for IRQ will be performed, regardless of the state interrupt
//     mask flag. The vector address loaded into the program
//     counter, low and high, are locations FFFA and FFFB respectively, thereby transferring program control to the memory
//     vector located at these addresses. The instructions loaded
//     at these locations cause the microprocessor to branch to a
//     non-maskable interrupt routine in memory.
//     NMI also requires an external 3K resistor to Vcc for proper
//     wire-OR operations.
//     Inputs IRQ and NMI are hardware interrupts lines that are
//     sampled during $2 (phase 2) and will begin the appropriate
//     interrupt routine on the 1 (phase 1) following the completion of the current instruction.
// TODO: bank-switching

/// 8-Bit Microprocessor
pub const MOS6502 = struct {
    inputs: Inputs = .zero,
    clock_cycles: usize = 0,
    registers: Registers = .{
        .s = .fromInt(0xFF),
    },
    flags: Flags = .zero,
    data_bus: Byte = .zero,
    instruction_register: Byte = .fromInt(Instructions.NOP.available_modes.get(.implicit).?.opcode),
    address_bus: Word = .zero,
    read_write: ReadWrite = .read,
    instr_cycle_count: u4 = 0,
    instr_addr: ?u16 = null,
    is_starting_up: u1 = 0,

    pub fn init() @This() {
        return .{};
    }

    pub fn reset(self: *@This()) void {
        const inputs = self.inputs;
        self.* = .{};
        self.inputs = inputs;
    }

    pub const CpuEvent = union(enum) {
        wait,
        execute_instruction: struct {
            executed_instr_addr: ?u16,
            instruction_executed: u8,
            next_opcode: u8,

            /// Specific to Atari2600
            pub fn getInstruction(self: @This(), source: []const u8) Instruction.DecodeError!?Instruction {
                const prev_instr_addr: u13 = @as(u13, @truncate((self.executed_instr_addr orelse return null) - 0x1000)) % @as(u13, @truncate(source.len));
                const instruction, _ = try Instruction.decode(source[prev_instr_addr..]);
                return instruction;
            }
        },
        read: u16,
        write: struct { addr: u16, data: u8 },
    };

    pub fn update(self: *@This()) Error!CpuEvent {
        if (self.inputs.clock == 1) return .wait;
        self.clock_cycles += 1;

        defer self.inputs.prev_res = self.inputs.res;

        if (self.is_starting_up == 1) {
            switch (self.instr_cycle_count) {
                0 => {
                    self.read_write = .read;
                    self.address_bus = .fromInt(0xFFFC);
                    self.flags.irq_disable = 1;
                    self.instr_cycle_count +%= 1;
                    return .{ .read = 0xFFFC };
                },
                1 => {
                    self.registers.pc.lo = self.data_bus;
                    self.read_write = .read;
                    self.address_bus = .fromInt(0xFFFD);
                    self.instr_cycle_count +%= 1;
                    return .{ .read = 0xFFFD };
                },
                2 => {
                    self.registers.pc.hi = self.data_bus;
                    self.address_bus = self.registers.pc;
                    self.registers.pc.inc();
                    self.is_starting_up = 0;
                    self.instr_cycle_count = 1;
                    return .{ .read = self.address_bus.toInt() };
                },
                else => return Error.InvalidState,
            }
        }

        if (self.inputs.res == 1 and self.inputs.prev_res == 0) {
            self.is_starting_up = 1;
            self.instr_cycle_count = 0;
            self.clock_cycles = 0;
            return .wait;
        }

        const instr_cycle_count = self.instr_cycle_count;

        defer {
            if ((~self.inputs.rdy) & @intFromEnum(self.read_write) == 1) {
                self.instr_cycle_count = instr_cycle_count;
            } else {
                self.registers.pc = .fromInt(self.registers.pc.toInt() +% 1);
            }
        }

        var event: ?CpuEvent = null;

        switch (self.instr_cycle_count) {
            0 => {
                _ = try self.executeWithAddressingMode();
                self.address_bus = self.registers.pc;
                self.read_write = .read;
                self.instr_cycle_count +%= 1;
            },
            else => {
                if (self.instr_cycle_count == 1) {
                    event = .{ .execute_instruction = .{
                        .executed_instr_addr = self.instr_addr,
                        .instruction_executed = self.instruction_register.toInt(),
                        .next_opcode = self.data_bus.toInt(),
                    } };
                    self.instruction_register = self.data_bus;
                    self.instr_addr = self.address_bus.toInt();
                }
                switch (try self.executeWithAddressingMode()) {
                    .cont => self.instr_cycle_count +%= 1,
                    .cont_no_pc_inc => {
                        self.instr_cycle_count +%= 1;
                        self.registers.pc = .fromInt(self.registers.pc.toInt() -% 1);
                    },
                    .next_instruction => self.instr_cycle_count = 0,
                    .next_instruction_no_pc_inc => {
                        self.instr_cycle_count = 0;
                        self.registers.pc = .fromInt(self.registers.pc.toInt() -% 1);
                    },
                }
            },
        }

        return event orelse switch (self.read_write) {
            .read => .{ .read = self.address_bus.toInt() },
            .write => .{ .write = .{ .addr = self.address_bus.toInt(), .data = self.data_bus.toInt() } },
        };
    }

    const ExecuteEvent = enum { cont, cont_no_pc_inc, next_instruction, next_instruction_no_pc_inc };

    fn executeWithAddressingMode(self: *@This()) Error!ExecuteEvent {
        const instr_type = try self.getInstrType();
        {
            if ((try self.getInstrType()).operation_type == .undecided) {
                @panic(std.fmt.allocPrint(std.heap.page_allocator, "operation type of {s} is undecided", .{instr_type.mnemonic}) catch unreachable);
            }
        }

        if (instr_type.operation_type == .brk) {
            // TODO: support irq, nmi or res
            const is_hardware_interrupt = false;
            return switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                2 => {
                    self.read_write = .write;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    self.data_bus = self.registers.pc.hi;
                    self.registers.s = self.registers.s.sub(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                3 => {
                    self.read_write = .write;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    self.data_bus = self.registers.pc.lo;
                    self.registers.s = self.registers.s.sub(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                4 => {
                    self.read_write = .write;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    self.data_bus = @bitCast(self.flags);
                    self.data_bus.b4 = if (is_hardware_interrupt) 0 else 1;
                    self.data_bus.b5 = 1;
                    self.registers.s = self.registers.s.sub(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                5 => {
                    self.read_write = .read;
                    // TODO: support nmi and res
                    self.address_bus = .fromInt(0xFFFE);
                    return .cont_no_pc_inc;
                },
                6 => {
                    self.read_write = .read;
                    self.registers.dl = self.data_bus;
                    // TODO: support nmi and res
                    self.address_bus = .fromInt(0xFFFF);
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.registers.dl;
                    self.address_bus.hi = self.data_bus;
                    self.registers.pc = self.address_bus;
                    if (is_hardware_interrupt) {
                        self.flags.irq_disable = 1;
                    }
                    return .cont;
                },
                else => Error.InvalidState,
            };
        } else if (instr_type.operation_type == .rti) {
            return switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont_no_pc_inc;
                },
                2 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    self.registers.s = self.registers.s.add(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                3 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    self.registers.s = self.registers.s.add(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                4 => {
                    self.read_write = .read;
                    self.registers.dl = self.data_bus;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    self.registers.s = self.registers.s.add(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                5 => {
                    self.read_write = .read;
                    self.registers.pc.lo = self.data_bus;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    self.read_write = .read;
                    self.registers.pc.hi = self.data_bus;
                    self.address_bus = self.registers.pc;
                    self.flags = @bitCast(self.registers.dl.toInt() & 0b11001111);
                    return .cont;
                },
                else => Error.InvalidState,
            };
        } else if (instr_type.operation_type == .jmp) {
            return switch (try self.getAddressingMode()) {
                .absolute => switch (self.instr_cycle_count) {
                    1 => {
                        self.read_write = .read;
                        self.address_bus = self.registers.pc;
                        return .cont;
                    },
                    2 => {
                        self.read_write = .read;
                        self.address_bus = self.registers.pc;
                        self.registers.pc.lo = self.data_bus;
                        return .next_instruction_no_pc_inc;
                    },
                    0 => {
                        self.read_write = .read;
                        self.registers.pc.hi = self.data_bus;
                        self.address_bus = self.registers.pc;
                        return .cont;
                    },
                    else => Error.InvalidState,
                },
                .indirect_absolute => switch (self.instr_cycle_count) {
                    1 => {
                        self.read_write = .read;
                        self.address_bus = self.registers.pc;
                        return .cont;
                    },
                    2 => {
                        self.read_write = .read;
                        self.address_bus = self.registers.pc;
                        self.registers.dl = self.data_bus;
                        return .cont;
                    },
                    3 => {
                        self.read_write = .read;
                        self.address_bus.lo = self.registers.dl;
                        self.address_bus.hi = self.data_bus;
                        return .cont;
                    },
                    4 => {
                        self.read_write = .read;
                        self.registers.dl = self.data_bus;
                        self.address_bus.lo = self.address_bus.lo.add(.fromInt(1));
                        return .next_instruction;
                    },
                    0 => {
                        self.read_write = .read;
                        self.registers.pc.lo = self.registers.dl;
                        self.registers.pc.hi = self.data_bus;
                        self.address_bus = self.registers.pc;
                        return .cont;
                    },
                    else => Error.InvalidState,
                },
                else => Error.InvalidState,
            };
        } else if (instr_type.operation_type == .rts) {
            return switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont_no_pc_inc;
                },
                2 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    self.registers.s = self.registers.s.add(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                3 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    self.registers.s = self.registers.s.add(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                4 => {
                    self.read_write = .read;
                    self.registers.pc.lo = self.data_bus;
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    return .cont_no_pc_inc;
                },
                5 => {
                    self.read_write = .read;
                    self.registers.pc.hi = self.data_bus;
                    self.address_bus = self.registers.pc;
                    return .next_instruction;
                },
                0 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                else => Error.InvalidState,
            };
        } else if (instr_type.operation_type == .branch) {
            return switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    const target = self.getTarget(instr_type.implicit_target);
                    try self.executeSubInstr(instr_type.sub_instruction, target, null);
                    if (self.registers.dl.b0 == 0) {
                        return .next_instruction;
                    } else {
                        return .cont;
                    }
                },
                2 => {
                    self.read_write = .read;
                    const offset = self.data_bus;
                    const offset_i8: i8 = @bitCast(offset);
                    var carry: u1 = 0;
                    if (offset_i8 < 0) {
                        self.address_bus.lo, carry = self.registers.pc.lo.subWithOverflow(.fromInt(@abs(offset_i8)));
                    } else {
                        self.address_bus.lo, carry = self.registers.pc.lo.addWithOverflow(offset);
                    }
                    self.address_bus.hi = self.registers.pc.hi;
                    self.registers.pc = self.address_bus;
                    self.registers.dl = offset;
                    if (carry == 0) {
                        return .next_instruction_no_pc_inc;
                    } else {
                        return .cont_no_pc_inc;
                    }
                },
                3 => {
                    self.read_write = .read;
                    const offset = self.registers.dl;
                    const offset_i8: i8 = @bitCast(offset);
                    if (offset_i8 < 0) {
                        self.address_bus.hi = self.address_bus.hi.sub(.fromInt(1));
                    } else {
                        self.address_bus.hi = self.address_bus.hi.add(.fromInt(1));
                    }
                    self.registers.pc = self.address_bus;
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                else => Error.InvalidState,
            };
        }

        return switch (try self.getAddressingMode()) {
            .implicit => switch (self.instr_cycle_count) {
                1 => {
                    self.address_bus = self.registers.pc;
                    switch (instr_type.operation_type) {
                        .read, .rmw => {},
                        .stack_push, .stack_pull => return .cont_no_pc_inc,
                        else => return Error.InvalidState,
                    }
                    return .next_instruction_no_pc_inc;
                },
                2 => {
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    switch (instr_type.operation_type) {
                        .stack_push => {
                            self.read_write = .write;
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, null);
                            self.registers.s = self.registers.s.sub(.fromInt(1));
                        },
                        .stack_pull => {
                            self.read_write = .read;
                            return .cont_no_pc_inc;
                        },
                        else => return Error.InvalidState,
                    }
                    return .next_instruction_no_pc_inc;
                },
                3 => {
                    self.read_write = .read;
                    self.registers.s = self.registers.s.add(.fromInt(1));
                    self.address_bus.lo = self.registers.s;
                    self.address_bus.hi = .fromInt(1);
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    switch (instr_type.operation_type) {
                        .read, .stack_pull => {
                            const target = self.getTarget(instr_type.implicit_target);
                            var data: Byte = .fromInt(if (instr_type.operation_type == .stack_pull and instr_type.implicit_target == .sr)
                                self.data_bus.toInt() & 0b11001111
                            else
                                self.data_bus.toInt());
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&data));
                        },
                        .rmw => {
                            // const target = TargetPtr.from(&self.data_bus);
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, null);
                        },
                        .stack_push => {},
                        else => return Error.InvalidState,
                    }
                    return .cont;
                },
                else => Error.InvalidState,
            },
            .immediate => switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .next_instruction;
                },
                0 => {
                    const target = self.getTarget(instr_type.implicit_target);
                    try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                    return .cont;
                },
                else => Error.InvalidState,
            },
            .zero => switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                2 => {
                    self.address_bus.hi = .zero;
                    self.address_bus.lo = self.data_bus;

                    switch (instr_type.operation_type) {
                        .read => {
                            self.read_write = .read;
                        },
                        .store => {
                            self.read_write = .write;
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .rmw => {
                            self.read_write = .read;
                            return .cont_no_pc_inc;
                        },
                        else => return Error.InvalidState,
                    }
                    return .next_instruction_no_pc_inc;
                },
                3 => {
                    self.read_write = .write;
                    return .cont_no_pc_inc;
                },
                4 => {
                    self.read_write = .write;
                    const target = TargetPtr.from(&self.data_bus);
                    try self.executeSubInstr(instr_type.sub_instruction, target, null);
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    switch (instr_type.operation_type) {
                        .read => {
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .store => {},
                        .rmw => {},
                        else => return Error.InvalidState,
                    }
                    return .cont;
                },
                else => Error.InvalidState,
            },
            .absolute => switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                2 => {
                    self.read_write = .read;
                    self.registers.dl = self.data_bus;
                    switch (instr_type.operation_type) {
                        .jsr => {
                            self.address_bus.lo = self.registers.s;
                            self.address_bus.hi = .fromInt(1);
                            return .cont_no_pc_inc;
                        },
                        .read, .store, .rmw => {
                            self.address_bus = self.registers.pc;
                        },
                        else => return Error.InvalidState,
                    }
                    return .cont;
                },
                3 => {
                    self.address_bus.lo = self.registers.dl;
                    self.address_bus.hi = self.data_bus;
                    switch (instr_type.operation_type) {
                        .read => {
                            self.read_write = .read;
                        },
                        .store => {
                            self.read_write = .write;
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .rmw => {
                            self.read_write = .read;
                            return .cont_no_pc_inc;
                        },
                        .jsr => {
                            self.read_write = .write;
                            self.address_bus.lo = self.registers.s;
                            self.address_bus.hi = .fromInt(1);
                            self.data_bus = self.registers.pc.hi;
                            self.registers.s = self.registers.s.sub(.fromInt(1));
                            return .cont_no_pc_inc;
                        },
                        else => return Error.InvalidState,
                    }

                    return .next_instruction_no_pc_inc;
                },
                4 => {
                    self.read_write = .write;
                    switch (instr_type.operation_type) {
                        .jsr => {
                            self.address_bus.lo = self.registers.s;
                            self.address_bus.hi = .fromInt(1);
                            self.data_bus = self.registers.pc.lo;
                            self.registers.s = self.registers.s.sub(.fromInt(1));
                        },
                        .rmw => {},
                        else => return Error.InvalidState,
                    }
                    return .cont_no_pc_inc;
                },
                5 => {
                    switch (instr_type.operation_type) {
                        .jsr => {
                            self.read_write = .read;
                            self.address_bus = self.registers.pc;
                        },
                        .rmw => {
                            self.read_write = .write;
                            try self.executeSubInstr(instr_type.sub_instruction, .from(&self.data_bus), null);
                        },
                        else => return Error.InvalidState,
                    }
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    switch (instr_type.operation_type) {
                        .read => {
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .jsr => {
                            self.address_bus.lo = self.registers.dl;
                            self.address_bus.hi = self.data_bus;
                            self.registers.pc = self.address_bus;
                        },
                        .store, .rmw => {},
                        else => return Error.InvalidState,
                    }

                    return .cont;
                },
                else => Error.InvalidState,
            },
            .pre_indexed_indirect_zero_x => switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                2 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.data_bus;
                    self.address_bus.hi = .zero;
                    return .cont_no_pc_inc;
                },
                3 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.address_bus.lo.add(self.registers.x);
                    return .cont_no_pc_inc;
                },
                4 => {
                    self.read_write = .read;
                    self.registers.dl = self.data_bus;
                    self.address_bus.lo = self.address_bus.lo.add(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                5 => {
                    self.address_bus.lo = self.registers.dl;
                    self.address_bus.hi = self.data_bus;

                    switch (instr_type.operation_type) {
                        .read => {
                            self.read_write = .read;
                        },
                        .store => {
                            self.read_write = .write;
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .rmw => return .cont_no_pc_inc,
                        else => return Error.InvalidState,
                    }

                    return .next_instruction_no_pc_inc;
                },
                6 => {
                    self.read_write = .write;
                    return .cont_no_pc_inc;
                },
                7 => {
                    self.read_write = .write;
                    const target = self.getTarget(instr_type.implicit_target);
                    try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    switch (instr_type.operation_type) {
                        .read => {
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .store, .rmw => {},
                        else => return Error.InvalidState,
                    }
                    return .cont;
                },
                else => Error.InvalidState,
            },
            .post_indexed_indirect_zero_y => switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                2 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.data_bus;
                    self.address_bus.hi = .zero;
                    return .cont_no_pc_inc;
                },
                3 => {
                    self.read_write = .read;
                    self.registers.dl = self.data_bus;
                    self.address_bus.lo = self.address_bus.lo.add(.fromInt(1));
                    return .cont_no_pc_inc;
                },
                4 => {
                    self.read_write = .read;
                    self.address_bus.lo, const carry = self.registers.dl.addWithOverflow(self.registers.y);
                    self.address_bus.hi = self.data_bus;
                    switch (instr_type.operation_type) {
                        .read => {
                            if (carry == 0) {
                                return .next_instruction_no_pc_inc;
                            } else {
                                self.address_bus.hi = self.address_bus.hi.add(.fromInt(1));
                                return .cont_no_pc_inc;
                            }
                        },
                        .store => return .cont_no_pc_inc,
                        else => return Error.InvalidState,
                    }
                },
                5 => {
                    switch (instr_type.operation_type) {
                        .read => {
                            self.read_write = .read;
                        },
                        .store => {
                            self.read_write = .write;
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        else => return Error.InvalidState,
                    }
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    switch (instr_type.operation_type) {
                        .read => {
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .store => {},
                        else => return Error.InvalidState,
                    }
                    return .cont;
                },
                else => Error.InvalidState,
            },
            .indexed_absolute_x, .indexed_absolute_y => |t| switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                2 => {
                    self.read_write = .read;
                    self.registers.dl = self.data_bus;
                    self.address_bus = self.registers.pc;
                    return .cont_no_pc_inc;
                },
                3 => {
                    self.read_write = .read;
                    const index = switch (t) {
                        .indexed_absolute_x => self.registers.x,
                        .indexed_absolute_y => self.registers.y,
                        else => return Error.InvalidState,
                    };
                    self.address_bus.lo, const carry = self.registers.dl.addWithOverflow(index);
                    self.address_bus.hi = self.data_bus.add(.fromInt(carry));
                    switch (instr_type.operation_type) {
                        .read => {
                            if (carry == 0) {
                                return .next_instruction;
                            } else {
                                return .cont_no_pc_inc;
                            }
                        },
                        .store, .rmw => return .cont_no_pc_inc,
                        else => return Error.InvalidState,
                    }
                },
                4 => {
                    switch (instr_type.operation_type) {
                        .read => {
                            self.read_write = .read;
                        },
                        .store => {
                            self.read_write = .write;
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .rmw => return .cont_no_pc_inc,
                        else => return Error.InvalidState,
                    }
                    return .next_instruction;
                },
                5 => {
                    self.read_write = .write;
                    return .cont_no_pc_inc;
                },
                6 => {
                    self.read_write = .write;
                    try self.executeSubInstr(instr_type.sub_instruction, .from(&self.data_bus), null);
                    return .next_instruction;
                },
                0 => {
                    switch (instr_type.operation_type) {
                        .read => {
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .store, .rmw => {},
                        else => return Error.InvalidState,
                    }
                    return .cont;
                },
                else => Error.InvalidState,
            },
            .indexed_zero_x, .indexed_zero_y => |t| switch (self.instr_cycle_count) {
                1 => {
                    self.read_write = .read;
                    self.address_bus = self.registers.pc;
                    return .cont;
                },
                2 => {
                    self.read_write = .read;
                    self.address_bus.lo = self.data_bus;
                    self.address_bus.hi = .zero;
                    return .cont_no_pc_inc;
                },
                3 => {
                    const index = switch (t) {
                        .indexed_zero_x => self.registers.x,
                        .indexed_zero_y => self.registers.y,
                        else => return Error.InvalidState,
                    };
                    self.address_bus.lo = self.address_bus.lo.add(index);

                    switch (instr_type.operation_type) {
                        .read => {
                            self.read_write = .read;
                        },
                        .store => {
                            self.read_write = .write;
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .rmw => return .cont_no_pc_inc,
                        else => return Error.InvalidState,
                    }
                    return .next_instruction_no_pc_inc;
                },
                4 => {
                    self.read_write = .write;
                    return .cont_no_pc_inc;
                },
                5 => {
                    self.read_write = .write;
                    try self.executeSubInstr(instr_type.sub_instruction, .from(&self.data_bus), null);
                    return .next_instruction_no_pc_inc;
                },
                0 => {
                    switch (instr_type.operation_type) {
                        .read => {
                            const target = self.getTarget(instr_type.implicit_target);
                            try self.executeSubInstr(instr_type.sub_instruction, target, .from(&self.data_bus));
                        },
                        .store, .rmw => {},
                        else => return Error.InvalidState,
                    }
                    return .cont;
                },
                else => Error.InvalidState,
            },
            else => |t| {
                std.log.err("unimplemented addressing mode: {t}", .{t});
                return Error.UnimplementedAddressingMode;
            },
        };
    }

    fn aluShiftLeft(self: *@This(), target: *Byte) void {
        const byte, self.flags.carry = @shlWithOverflow(target.toIntPtr().*, 1);
        target.* = .fromInt(byte);
        self.flags.setZero(target.*);
        self.flags.setNegative(target.*);
    }

    fn aluShiftRight(self: *@This(), target: *Byte) void {
        self.flags.carry = @truncate(target.toInt());
        target.* = .fromInt(target.toInt() >> 1);
        self.flags.setZero(target.*);
        self.flags.negative = 0;
    }

    fn aluInc(self: *@This(), target: *Byte) void {
        target.* = .fromInt(target.toInt() +% 1);
        self.flags.setZero(target.*);
        self.flags.setNegative(target.*);
    }

    fn aluDec(self: *@This(), target: *Byte) void {
        target.* = .fromInt(target.toInt() -% 1);
        self.flags.setZero(target.*);
        self.flags.setNegative(target.*);
    }

    fn aluRotateLeft(self: *@This(), target: *Byte) void {
        const prev_carry = self.flags.carry;
        const byte, self.flags.carry = @shlWithOverflow(target.toIntPtr().*, 1);
        target.* = .fromInt(byte | prev_carry);
        self.flags.setZero(target.*);
        self.flags.setNegative(target.*);
    }

    fn aluRotateRight(self: *@This(), target: *Byte) void {
        const prev_carry = self.flags.carry;
        self.flags.carry = @truncate(target.toInt() & 1);
        target.* = .fromInt(std.math.rotr(u8, target.toInt(), 1));
        target.b7 = prev_carry;
        self.flags.setZero(target.*);
        self.flags.setNegative(target.*);
    }

    fn aluAddWithCarry(self: *@This(), dest: *Byte, rhs: *Byte) void {
        switch (self.flags.decimal_mode) {
            0 => {
                const dest_prev = dest.toInt();
                var result, const carry = @addWithOverflow(dest.toInt(), rhs.toInt());

                if (self.flags.carry > 0) {
                    result, self.flags.carry = @addWithOverflow(result, self.flags.carry);
                }

                self.flags.carry |= carry;

                dest.* = .fromInt(result);
                self.flags.overflow = @truncate((~(dest_prev ^ rhs.toInt()) & (dest_prev ^ result)) >> 7);
            },
            1 => {
                var c: Byte = .zero;
                {
                    var carry = self.flags.carry;
                    for (0..4) |i| {
                        const bit: u3 = @truncate(i);
                        const carry_with_result: u2 = @as(u2, dest.getBit(bit)) + @as(u2, rhs.getBit(bit)) + @as(u2, carry);
                        dest.setBit(bit, @truncate(carry_with_result));
                        carry = @truncate(carry_with_result >> 1);
                        c.setBit(bit, carry);
                    }
                }

                var correction_carry_lo: u1 = c.b3;
                var result_lo = dest.nibble(0);
                if (result_lo >= 0xa or correction_carry_lo == 1) {
                    result_lo +%= 6;
                    correction_carry_lo = 1;
                    dest.setNibble(0, result_lo);
                }

                {
                    var carry = correction_carry_lo;
                    for (4..8) |i| {
                        const bit: u3 = @truncate(i);
                        const carry_with_result: u2 = @as(u2, dest.getBit(bit)) + @as(u2, rhs.getBit(bit)) + @as(u2, carry);
                        dest.setBit(bit, @truncate(carry_with_result));
                        carry = @truncate(carry_with_result >> 1);
                        c.setBit(bit, carry);
                    }
                }

                self.flags.overflow = c.b6 ^ c.b7;
                var correction_carry_hi = c.b7;
                var result_hi = dest.nibble(1);

                if (result_hi >= 0xa or correction_carry_hi == 1) {
                    result_hi +%= 6;
                    correction_carry_hi = 1;
                    dest.setNibble(1, result_hi);
                }

                self.flags.carry = correction_carry_hi;
            },
        }

        self.flags.setZero(dest.*);
        self.flags.setNegative(dest.*);
    }

    fn aluSubWithCarry(self: *@This(), dest: *Byte, rhs: *Byte) void {
        switch (self.flags.decimal_mode) {
            0 => {
                const rhs_inv = ~rhs.toInt();
                var result, const carry = @addWithOverflow(dest.toInt(), rhs_inv);

                if (self.flags.carry == 1) {
                    result, self.flags.carry = @addWithOverflow(result, 1);
                }

                self.flags.carry |= carry;

                self.flags.overflow = @truncate((~(dest.toInt() ^ rhs_inv) & (dest.toInt() ^ result)) >> 7);
                dest.* = .fromInt(result);
            },
            1 => {
                const dest_prev = dest.*;
                const rhs_inv = ~rhs.toInt();
                const rhs_inv_b = Byte.fromInt(rhs_inv);
                var result, const carry = @addWithOverflow(dest.toInt(), rhs_inv);

                if (self.flags.carry == 1) {
                    result, self.flags.carry = @addWithOverflow(result, 1);
                }

                self.flags.carry |= carry;

                self.flags.overflow = @truncate((~(dest.toInt() ^ rhs_inv) & (dest.toInt() ^ result)) >> 7);
                dest.* = .fromInt(result);

                _, const carry_lo = @addWithOverflow(dest_prev.nibble(0), rhs_inv_b.nibble(0));
                var result_lo = dest.nibble(0);
                if (result_lo >= 0xa or carry_lo == 0) {
                    result_lo -%= 6;
                    dest.setNibble(0, result_lo);
                }

                var result_hi = dest.nibble(1);
                if (result_hi >= 0xa or self.flags.carry == 0) {
                    result_hi -%= 6;
                    dest.setNibble(1, result_hi);
                }
            },
        }

        self.flags.setZero(dest.*);
        self.flags.setNegative(dest.*);
    }

    fn bitwiseAnd(self: *@This(), dest: *Byte, rhs: *Byte) void {
        dest.* = .fromInt(dest.toInt() & rhs.toInt());

        self.flags.setZero(dest.*);
        self.flags.setNegative(dest.*);
    }

    fn bitwiseOr(self: *@This(), dest: *Byte, rhs: *Byte) void {
        dest.* = .fromInt(dest.toInt() | rhs.toInt());

        self.flags.setZero(dest.*);
        self.flags.setNegative(dest.*);
    }

    fn BIT(self: *@This(), dest: *Byte, rhs: *Byte) void {
        // A AND M -> Z, M[7] -> N, M[6] -> V

        self.flags.setZero(.fromInt(dest.toInt() & rhs.toInt()));
        self.flags.negative = @truncate(rhs.toInt() >> 7);
        self.flags.overflow = @truncate(rhs.toInt() >> 6);
    }

    fn cmp(self: *@This(), dest: *Byte, rhs: *Byte) void {
        const result, self.flags.carry = @subWithOverflow(dest.toInt(), rhs.toInt());
        const byte = Byte.fromInt(result);
        self.flags.carry = ~self.flags.carry;
        self.flags.setZero(byte);
        self.flags.setNegative(byte);
    }

    fn xor(self: *@This(), dest: *Byte, rhs: *Byte) void {
        dest.* = .fromInt(dest.toInt() ^ rhs.toInt());
        self.flags.setZero(dest.*);
        self.flags.setNegative(dest.*);
    }

    fn getInstrType(self: @This()) Error!*const Instruction.Type {
        return opcode_type_table[self.instruction_register.toInt()] orelse return Error.InvalidOpCode;
    }

    fn getAddressingMode(self: @This()) Error!Instruction.AddressingModeTag {
        return opcode_mode_table[self.instruction_register.toInt()] orelse return Error.InvalidOpCode;
    }

    fn executeSubInstr(self: *@This(), sub_instr: CPUSubInstr, target: TargetPtr, arg: ?TargetPtr) Error!void {
        return switch (sub_instr) {
            .noop => {},
            .shift_left => self.aluShiftLeft(target.byte),
            .shift_right => self.aluShiftRight(target.byte),
            .rotate_left => self.aluRotateLeft(target.byte),
            .rotate_right => self.aluRotateRight(target.byte),
            .read => {
                target.byte.* = arg.?.byte.*;
                self.flags.setZero(target.byte.*);
                self.flags.setNegative(target.byte.*);
            },
            .write => |write| {
                const dest = target.byte;
                dest.* = self.getTarget(write.src).byte.*;
                self.flags.setZero(dest.*);
                self.flags.setNegative(dest.*);
            },
            .write_no_set_flags => |write| {
                target.byte.* = self.getTarget(write.src).byte.*;
            },
            .clear_flag => target.setFlag(0),
            .set_flag => target.setFlag(1),
            .dec => self.aluDec(target.byte),
            .inc => self.aluInc(target.byte),
            .add_with_carry => self.aluAddWithCarry(target.byte, arg.?.byte),
            .sub_with_carry => self.aluSubWithCarry(target.byte, arg.?.byte),
            .bitwise_and => self.bitwiseAnd(target.byte, arg.?.byte),
            .bitwise_or => self.bitwiseOr(target.byte, arg.?.byte),
            .BIT => self.BIT(target.byte, arg.?.byte),
            .cmp => self.cmp(target.byte, arg.?.byte),
            .eor => self.xor(target.byte, arg.?.byte),
            .is_clear => self.registers.dl.b0 = ~(target.getFlag()),
            .is_set => self.registers.dl.b0 = target.getFlag(),
            .unimplemented => Error.UnimplementedInstruction,
        };
    }

    const TargetPtr = union {
        byte: *Byte,
        flag: struct { container: *Flags, bit: u3 },

        pub fn setFlag(self: @This(), value: u1) void {
            const container_as_byte: *Byte = @ptrCast(self.flag.container);
            container_as_byte.setBit(self.flag.bit, value);
        }

        pub fn getFlag(self: @This()) u1 {
            const container_as_byte: *Byte = @ptrCast(self.flag.container);
            return container_as_byte.getBit(self.flag.bit);
        }

        pub fn initFlag(container: *Flags, bit: u3) @This() {
            return .{ .flag = .{ .container = container, .bit = bit } };
        }

        pub fn from(src: anytype) @This() {
            if (@TypeOf(src) == *Byte) {
                return .{ .byte = src };
            } else if (@TypeOf(src) == *Flags) {
                return .{ .byte = @ptrCast(@alignCast(src)) };
            } else if (@TypeOf(src) == *u1) {
                return .{ .flag = src };
            } else switch (@typeInfo(@typeInfo(@TypeOf(src)).pointer.child)) {
                .int => |s| {
                    if (s.bits == 1) {
                        return .{ .flag = src };
                    } else if (s.bits == 8) {
                        return .{ .flag = @ptrCast(src) };
                    }
                },
                else => {},
            }

            @compileError("invalid src " ++ @typeName(@TypeOf(src)));
        }
    };

    fn getTarget(self: *@This(), target: CPUTarget) TargetPtr {
        return switch (target) {
            .a => .from(&self.registers.a),
            .x => .from(&self.registers.x),
            .y => .from(&self.registers.y),
            .s => .from(&self.registers.s),
            .pcl => .from(@as(*Byte, @ptrCast(&self.registers.pc.lo))),
            .pch => .from(@as(*Byte, @ptrCast(&self.registers.pc.hi))),
            .db => .from(&self.data_bus),
            .c => .initFlag(&self.flags, 0),
            .z => .initFlag(&self.flags, 1),
            .i => .initFlag(&self.flags, 2),
            .d => .initFlag(&self.flags, 3),
            .v => .initFlag(&self.flags, 6),
            .n => .initFlag(&self.flags, 7),
            .sr => .from(&self.flags),
        };
    }

    pub const Error = error{
        InvalidOpCode,
        InvalidState,
        UnimplementedInstruction,
        UnimplementedAddressingMode,
    };

    pub const Inputs = struct {
        clock: u1 = 0,
        interrupt_request: u1 = 0,
        non_maskable_interrupt: u1 = 0,
        rdy: u1 = 1,
        res: u1 = 1,
        prev_res: u1 = 0,

        pub const zero = @This(){};
    };

    pub const Registers = struct {
        a: Byte = .zero,
        x: Byte = .zero,
        y: Byte = .zero,
        pc: Word = .zero,
        s: Byte = .zero,
        dl: Byte = .zero,

        pub const zero = @This(){};
    };

    pub const Flags = packed struct(u8) {
        carry: u1 = 0,
        zero_: u1 = 0,
        irq_disable: u1 = 0,
        decimal_mode: u1 = 0,
        break_command: u1 = 0,
        _: u1 = 0,
        overflow: u1 = 0,
        negative: u1 = 0,

        pub const zero = @This(){};

        fn setZero(self: *@This(), target: Byte) void {
            self.zero_ = @intFromBool(target.toInt() == 0);
        }

        fn setNegative(self: *@This(), target: Byte) void {
            self.negative = @intFromBool(std.math.signbit(@as(i8, @bitCast(target))));
        }
    };

    const CPUTarget = enum { a, x, y, s, pcl, pch, db, z, c, v, i, d, n, sr };
    const CPUSubInstr = union(enum) {
        noop,
        shift_left,
        shift_right,
        rotate_left,
        rotate_right,
        read,
        write: struct { src: CPUTarget },
        write_no_set_flags: struct { src: CPUTarget },
        clear_flag,
        set_flag,
        dec,
        inc,
        add_with_carry,
        sub_with_carry,
        bitwise_and,
        bitwise_or,
        BIT,
        cmp,
        eor,
        is_clear,
        is_set,
        unimplemented,
    };
};

// INSTRUCTION SET

pub const Instruction = struct {
    type: *const Type,
    mode: AddressingMode,

    pub fn decode(source: []const u8) DecodeError!struct { @This(), usize } {
        @setEvalBranchQuota(100000);

        if (source.len == 0) return DecodeError.EndOfSource;
        const opcode = source[0];
        const instr_type = opcode_type_table[opcode] orelse return DecodeError.InvalidOpcode;
        const mode = opcode_mode_table[opcode] orelse return DecodeError.InvalidOpcode;

        switch (mode) {
            inline else => |t| {
                const Instr = std.meta.fieldInfo(AddressingMode, t).type;
                const n_instr_bits = @bitSizeOf(Instr);
                const n_instr_bytes = comptime n_instr_bits / 8;

                if (source.len < n_instr_bytes) return DecodeError.SourceCutoff;

                const instr_bytes = source[0..n_instr_bytes];
                const instr_uint = std.mem.readInt(@Int(.unsigned, n_instr_bits), instr_bytes, .little);
                const instr: Instr = @bitCast(instr_uint);

                const addressing_mode = @unionInit(AddressingMode, @tagName(t), instr);

                return .{
                    .{
                        .type = instr_type,
                        .mode = addressing_mode,
                    },
                    n_instr_bytes,
                };
            },
        }
    }

    pub const DecodeError = error{ InvalidOpcode, EndOfSource, SourceCutoff };

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}", .{self.type.mnemonic});

        if (self.type.operation_type == .brk) {
            return writer.print("\n    DC.B ${x:02}", .{self.mode.immediate.arg});
        }

        try switch (self.mode) {
            .implicit => {},
            .immediate => |s| writer.print(" #${x:02}", .{s.arg}),
            .absolute => |s| writer.print(" ${f}", .{s.arg}),
            .zero => |s| writer.print(" ${x:02}", .{s.arg}),
            .indexed_absolute_x => |s| writer.print(" ${f},x", .{s.arg}),
            .indexed_absolute_y => |s| writer.print(" ${f},y", .{s.arg}),
            .indexed_zero_x => |s| writer.print(" ${x:02},x", .{s.arg}),
            .indexed_zero_y => |s| writer.print(" ${x:02},y", .{s.arg}),
            .indirect_absolute => |s| writer.print(" (${f})", .{s.arg}),
            .pre_indexed_indirect_zero_x => |s| writer.print(" (${x:02},x)", .{s.arg}),
            .post_indexed_indirect_zero_y => |s| writer.print(" (${x:02}),y", .{s.arg}),
            .relative => |s| writer.print(" * {s}{}", .{ if (s.arg + 2 == 0) "-" else "", s.arg + 2 }),
        };
    }

    pub const AddressingModeTag = enum {
        implicit,
        immediate,
        absolute,
        zero,
        indexed_absolute_x,
        indexed_absolute_y,
        indexed_zero_x,
        indexed_zero_y,
        indirect_absolute,
        pre_indexed_indirect_zero_x,
        post_indexed_indirect_zero_y,
        relative,

        pub fn byteSize(self: @This()) u2 {
            return switch (self) {
                .implicit => 1,
                .immediate => 2,
                .absolute => 3,
                .zero => 2,
                .indexed_absolute_x => 3,
                .indexed_absolute_y => 3,
                .indexed_zero_x => 2,
                .indexed_zero_y => 2,
                .indirect_absolute => 3,
                .pre_indexed_indirect_zero_x => 2,
                .post_indexed_indirect_zero_y => 2,
                .relative => 2,
            };
        }
    };

    pub const AddressingMode = union(AddressingModeTag) {
        implicit: packed struct(u8) {
            opcode: u8,
            arg: void,
        },
        immediate: packed struct(u16) {
            opcode: u8,
            arg: u8,
        },
        absolute: packed struct(u24) {
            opcode: u8,
            arg: Word,
        },
        zero: packed struct(u16) {
            opcode: u8,
            arg: u8,
        },
        indexed_absolute_x: packed struct(u24) {
            opcode: u8,
            arg: Word,
        },
        indexed_absolute_y: packed struct(u24) {
            opcode: u8,
            arg: Word,
        },
        indexed_zero_x: packed struct(u16) {
            opcode: u8,
            arg: u8,
        },
        indexed_zero_y: packed struct(u16) {
            opcode: u8,
            arg: u8,
        },
        indirect_absolute: packed struct(u24) {
            opcode: u8,
            arg: Word,
        },
        pre_indexed_indirect_zero_x: packed struct(u16) {
            opcode: u8,
            arg: u8,
        },
        post_indexed_indirect_zero_y: packed struct(u16) {
            opcode: u8,
            arg: u8,
        },
        relative: packed struct(u16) {
            opcode: u8,
            arg: i8,
        },
    };

    pub const Type = struct {
        mnemonic: *const [3:0]u8,
        description: []const u8,
        available_modes: AvailableModes,
        sub_instruction: MOS6502.CPUSubInstr = .unimplemented,
        implicit_target: MOS6502.CPUTarget = undefined,
        operation_type: OperationType = .undecided,

        pub const AvailableModes = std.enums.EnumMap(AddressingModeTag, ModeOptions);
        pub const ModeOptions = struct {
            opcode: u8,
            base_cycles: u4,

            pub fn init(opcode: u8, base_cycles: u4) @This() {
                return .{ .opcode = opcode, .base_cycles = base_cycles };
            }
        };
        pub const OperationType = enum { read, store, rmw, stack_push, stack_pull, jsr, brk, rti, jmp, rts, branch, undecided };

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{s}", .{self.mnemonic});
        }
    };

    pub fn ADC(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        @setEvalBranchQuota(100000);
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.ADC.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.ADC,
        };
    }
    pub fn AND(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.AND.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.AND,
        };
    }
    pub fn ASL(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.ASL.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.ASL,
        };
    }
    pub fn BCC(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BCC.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BCC,
        };
    }
    pub fn BCS(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BCS.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BCS,
        };
    }
    pub fn BEQ(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BEQ.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BEQ,
        };
    }
    pub fn BIT(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        @setEvalBranchQuota(100000);
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BIT.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BIT,
        };
    }
    pub fn BMI(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BMI.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BMI,
        };
    }
    pub fn BNE(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - @as(i8, if (arg < 0) 2 else 0) else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BNE.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BNE,
        };
    }
    pub fn BPL(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BPL.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BPL,
        };
    }
    pub fn BRK(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BRK.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BRK,
        };
    }
    pub fn BVC(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BVC.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BVC,
        };
    }
    pub fn BVS(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.BVS.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.BVS,
        };
    }
    pub fn CLC(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.CLC.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.CLC,
        };
    }
    pub fn CLD(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.CLD.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.CLD,
        };
    }
    pub fn CLI(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.CLI.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.CLI,
        };
    }
    pub fn CLV(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.CLV.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.CLV,
        };
    }
    pub fn CMP(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.CMP.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.CMP,
        };
    }
    pub fn CPX(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.CPX.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.CPX,
        };
    }
    pub fn CPY(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.CPY.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.CPY,
        };
    }
    pub fn DEC(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.DEC.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.DEC,
        };
    }
    pub fn DEX(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.DEX.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.DEX,
        };
    }
    pub fn DEY(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.DEY.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.DEY,
        };
    }
    pub fn EOR(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.EOR.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.EOR,
        };
    }
    pub fn INC(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.INC.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.INC,
        };
    }
    pub fn INX(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.INX.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.INX,
        };
    }
    pub fn INY(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.INY.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.INY,
        };
    }
    pub fn JMP(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.JMP.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.JMP,
        };
    }
    pub fn JSR(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.JSR.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.JSR,
        };
    }
    pub fn LDA(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.LDA.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.LDA,
        };
    }
    pub fn LDX(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.LDX.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.LDX,
        };
    }
    pub fn LDY(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.LDY.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.LDY,
        };
    }
    pub fn LSR(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.LSR.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.LSR,
        };
    }
    pub fn NOP(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.NOP.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.NOP,
        };
    }
    pub fn ORA(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.ORA.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.ORA,
        };
    }
    pub fn PHA(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.PHA.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.PHA,
        };
    }
    pub fn PHP(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.PHP.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.PHP,
        };
    }
    pub fn PLA(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.PLA.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.PLA,
        };
    }
    pub fn PLP(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.PLP.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.PLP,
        };
    }
    pub fn ROL(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        @setEvalBranchQuota(100000);
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.ROL.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.ROL,
        };
    }
    pub fn ROR(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        @setEvalBranchQuota(100000);
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.ROR.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.ROR,
        };
    }
    pub fn RTI(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.RTI.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.RTI,
        };
    }
    pub fn RTS(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.RTS.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.RTS,
        };
    }
    pub fn SBC(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        @setEvalBranchQuota(100000);
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.SBC.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.SBC,
        };
    }
    pub fn SEC(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.SEC.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.SEC,
        };
    }
    pub fn SED(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.SED.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.SED,
        };
    }
    pub fn SEI(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.SEI.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.SEI,
        };
    }
    pub fn STA(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.STA.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.STA,
        };
    }
    pub fn STX(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.STX.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.STX,
        };
    }
    pub fn STY(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.STY.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.STY,
        };
    }
    pub fn TAX(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.TAX.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.TAX,
        };
    }
    pub fn TAY(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.TAY.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.TAY,
        };
    }
    pub fn TSX(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.TSX.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.TSX,
        };
    }
    pub fn TXA(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.TXA.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.TXA,
        };
    }
    pub fn TXS(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.TXS.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.TXS,
        };
    }
    pub fn TYA(
        comptime mode: AddressingModeTag,
        arg: std.meta.fieldInfo(std.meta.fieldInfo(AddressingMode, mode).type, .arg).type,
    ) @This() {
        const arg_ = if (comptime mode == .relative) arg - 2 else arg;
        return .{
            .mode = @unionInit(AddressingMode, @tagName(mode), .{
                .opcode = Instructions.TYA.available_modes.get(mode).?.opcode,
                .arg = arg_,
            }),
            .type = &Instructions.TYA,
        };
    }
};

pub const Instructions = struct {
    pub const ADC = Instruction.Type{
        .mnemonic = "adc",
        .description = "add with carry",
        .sub_instruction = .add_with_carry,
        .implicit_target = .a,
        .operation_type = .read,
        .available_modes = .init(.{
            .immediate = .init(0x69, 2),
            .zero = .init(0x65, 3),
            .indexed_zero_x = .init(0x75, 4),
            .absolute = .init(0x6D, 4),
            .indexed_absolute_x = .init(0x7D, 4),
            .indexed_absolute_y = .init(0x79, 4),
            .pre_indexed_indirect_zero_x = .init(0x61, 6),
            .post_indexed_indirect_zero_y = .init(0x71, 5),
        }),
    };
    pub const AND = Instruction.Type{
        .mnemonic = "and",
        .description = "and (with accumulator)",
        .sub_instruction = .bitwise_and,
        .implicit_target = .a,
        .operation_type = .read,
        .available_modes = .init(.{
            .immediate = .init(0x29, 2),
            .zero = .init(0x25, 3),
            .indexed_zero_x = .init(0x35, 4),
            .absolute = .init(0x2D, 4),
            .indexed_absolute_x = .init(0x3D, 4),
            .indexed_absolute_y = .init(0x39, 4),
            .pre_indexed_indirect_zero_x = .init(0x21, 6),
            .post_indexed_indirect_zero_y = .init(0x31, 5),
        }),
    };
    pub const ASL = Instruction.Type{
        .mnemonic = "asl",
        .description = "arithmetic shift left",
        .sub_instruction = .shift_left,
        .implicit_target = .a,
        .operation_type = .rmw,
        .available_modes = .init(.{
            .implicit = .init(0x0A, 2),
            .zero = .init(0x06, 5),
            .indexed_zero_x = .init(0x16, 6),
            .absolute = .init(0x0E, 6),
            .indexed_absolute_x = .init(0x1E, 7),
        }),
    };
    pub const BCC = Instruction.Type{
        .mnemonic = "bcc",
        .description = "branch on carry clear",
        .operation_type = .branch,
        .sub_instruction = .is_clear,
        .implicit_target = .c,
        .available_modes = .init(.{
            .relative = .init(0x90, 2),
        }),
    };
    pub const BCS = Instruction.Type{
        .mnemonic = "bcs",
        .description = "branch on carry set",
        .operation_type = .branch,
        .sub_instruction = .is_set,
        .implicit_target = .c,
        .available_modes = .init(.{
            .relative = .init(0xB0, 2),
        }),
    };
    pub const BEQ = Instruction.Type{
        .mnemonic = "beq",
        .description = "branch on equal (zero set)",
        .operation_type = .branch,
        .sub_instruction = .is_set,
        .implicit_target = .z,
        .available_modes = .init(.{
            .relative = .init(0xF0, 2),
        }),
    };
    pub const BIT = Instruction.Type{
        .mnemonic = "bit",
        .description = "bit test",
        .operation_type = .read,
        .sub_instruction = .BIT,
        .implicit_target = .a,
        .available_modes = .init(.{
            .zero = .init(0x24, 3),
            .absolute = .init(0x2C, 4),
        }),
    };
    pub const BMI = Instruction.Type{
        .mnemonic = "bmi",
        .description = "branch on minus (negative set)",
        .operation_type = .branch,
        .sub_instruction = .is_set,
        .implicit_target = .n,
        .available_modes = .init(.{
            .relative = .init(0x30, 2),
        }),
    };
    pub const BNE = Instruction.Type{
        .mnemonic = "bne",
        .description = "branch on not equal (zero clear)",
        .operation_type = .branch,
        .sub_instruction = .is_clear,
        .implicit_target = .z,
        .available_modes = .init(.{
            .relative = .init(0xD0, 2),
        }),
    };
    pub const BPL = Instruction.Type{
        .mnemonic = "bpl",
        .description = "branch on plus (negative clear)",
        .operation_type = .branch,
        .sub_instruction = .is_clear,
        .implicit_target = .n,
        .available_modes = .init(.{
            .relative = .init(0x10, 2),
        }),
    };
    pub const BRK = Instruction.Type{
        .mnemonic = "brk",
        .description = "break / interrupt",
        .operation_type = .brk,
        .available_modes = .init(.{
            .immediate = .init(0x00, 7),
        }),
    };
    pub const BVC = Instruction.Type{
        .mnemonic = "bvc",
        .description = "branch on overflow clear",
        .operation_type = .branch,
        .sub_instruction = .is_clear,
        .implicit_target = .v,
        .available_modes = .init(.{
            .relative = .init(0x50, 2),
        }),
    };
    pub const BVS = Instruction.Type{
        .mnemonic = "bvs",
        .description = "branch on overflow set",
        .operation_type = .branch,
        .sub_instruction = .is_set,
        .implicit_target = .v,
        .available_modes = .init(.{
            .relative = .init(0x70, 2),
        }),
    };
    pub const CLC = Instruction.Type{
        .mnemonic = "clc",
        .description = "clear carry",
        .operation_type = .read,
        .sub_instruction = .clear_flag,
        .implicit_target = .c,
        .available_modes = .init(.{
            .implicit = .init(0x18, 2),
        }),
    };
    pub const CLD = Instruction.Type{
        .mnemonic = "cld",
        .description = "clear decimal",
        .operation_type = .read,
        .sub_instruction = .clear_flag,
        .implicit_target = .d,
        .available_modes = .init(.{
            .implicit = .init(0xD8, 2),
        }),
    };
    pub const CLI = Instruction.Type{
        .mnemonic = "cli",
        .description = "clear interrupt disable",
        .operation_type = .read,
        .sub_instruction = .clear_flag,
        .implicit_target = .i,
        .available_modes = .init(.{
            .implicit = .init(0x58, 2),
        }),
    };
    pub const CLV = Instruction.Type{
        .mnemonic = "clv",
        .description = "clear overflow",
        .operation_type = .read,
        .sub_instruction = .clear_flag,
        .implicit_target = .v,
        .available_modes = .init(.{
            .implicit = .init(0xB8, 2),
        }),
    };
    pub const CMP = Instruction.Type{
        .mnemonic = "cmp",
        .description = "compare (with accumulator)",
        .operation_type = .read,
        .sub_instruction = .cmp,
        .implicit_target = .a,
        .available_modes = .init(.{
            .immediate = .init(0xC9, 2),
            .zero = .init(0xC5, 3),
            .indexed_zero_x = .init(0xD5, 4),
            .absolute = .init(0xCD, 4),
            .indexed_absolute_x = .init(0xDD, 4),
            .indexed_absolute_y = .init(0xD9, 4),
            .pre_indexed_indirect_zero_x = .init(0xC1, 6),
            .post_indexed_indirect_zero_y = .init(0xD1, 5),
        }),
    };
    pub const CPX = Instruction.Type{
        .mnemonic = "cpx",
        .description = "compare with X",
        .operation_type = .read,
        .sub_instruction = .cmp,
        .implicit_target = .x,
        .available_modes = .init(.{
            .immediate = .init(0xE0, 2),
            .zero = .init(0xE4, 3),
            .absolute = .init(0xEC, 4),
        }),
    };
    pub const CPY = Instruction.Type{
        .mnemonic = "cpy",
        .description = "compare with Y",
        .operation_type = .read,
        .sub_instruction = .cmp,
        .implicit_target = .y,
        .available_modes = .init(.{
            .immediate = .init(0xC0, 2),
            .zero = .init(0xC4, 3),
            .absolute = .init(0xCC, 4),
        }),
    };
    pub const DEC = Instruction.Type{
        .mnemonic = "dec",
        .description = "decrement",
        .sub_instruction = .dec,
        .operation_type = .rmw,
        .available_modes = .init(.{
            .zero = .init(0xC6, 5),
            .indexed_zero_x = .init(0xD6, 6),
            .absolute = .init(0xCE, 6),
            .indexed_absolute_x = .init(0xDE, 7),
        }),
    };
    pub const DEX = Instruction.Type{
        .mnemonic = "dex",
        .description = "decrement X",
        .sub_instruction = .dec,
        .implicit_target = .x,
        .operation_type = .read,
        .available_modes = .init(.{
            .implicit = .init(0xCA, 2),
        }),
    };
    pub const DEY = Instruction.Type{
        .mnemonic = "dey",
        .description = "decrement Y",
        .sub_instruction = .dec,
        .implicit_target = .y,
        .operation_type = .read,
        .available_modes = .init(.{
            .implicit = .init(0x88, 2),
        }),
    };
    pub const EOR = Instruction.Type{
        .mnemonic = "eor",
        .description = "exclusive or (with accumulator)",
        .operation_type = .read,
        .sub_instruction = .eor,
        .implicit_target = .a,
        .available_modes = .init(.{
            .immediate = .init(0x49, 2),
            .zero = .init(0x45, 3),
            .indexed_zero_x = .init(0x55, 4),
            .absolute = .init(0x4D, 4),
            .indexed_absolute_x = .init(0x5D, 4),
            .indexed_absolute_y = .init(0x59, 4),
            .pre_indexed_indirect_zero_x = .init(0x41, 6),
            .post_indexed_indirect_zero_y = .init(0x51, 5),
        }),
    };
    pub const INC = Instruction.Type{
        .mnemonic = "inc",
        .description = "increment",
        .sub_instruction = .inc,
        .operation_type = .rmw,
        .available_modes = .init(.{
            .zero = .init(0xE6, 5),
            .indexed_zero_x = .init(0xF6, 6),
            .absolute = .init(0xEE, 6),
            .indexed_absolute_x = .init(0xFE, 7),
        }),
    };
    pub const INX = Instruction.Type{
        .mnemonic = "inx",
        .description = "increment X",
        .sub_instruction = .inc,
        .implicit_target = .x,
        .operation_type = .read,
        .available_modes = .init(.{
            .implicit = .init(0xE8, 2),
        }),
    };
    pub const INY = Instruction.Type{
        .mnemonic = "iny",
        .description = "increment Y",
        .sub_instruction = .inc,
        .implicit_target = .y,
        .operation_type = .read,
        .available_modes = .init(.{
            .implicit = .init(0xC8, 2),
        }),
    };
    pub const JMP = Instruction.Type{
        .mnemonic = "jmp",
        .description = "jump",
        .operation_type = .jmp,
        .available_modes = .init(.{
            .absolute = .init(0x4C, 3),
            .indirect_absolute = .init(0x6C, 5),
        }),
    };
    pub const JSR = Instruction.Type{
        .mnemonic = "jsr",
        .description = "jump subroutine",
        .operation_type = .jsr,
        .available_modes = .init(.{
            .absolute = .init(0x20, 6),
        }),
    };
    pub const LDA = Instruction.Type{
        .mnemonic = "lda",
        .description = "load accumulator",
        .sub_instruction = .read,
        .implicit_target = .a,
        .operation_type = .read,
        .available_modes = .init(.{
            .immediate = .init(0xA9, 2),
            .zero = .init(0xA5, 3),
            .indexed_zero_x = .init(0xB5, 4),
            .absolute = .init(0xAD, 4),
            .indexed_absolute_x = .init(0xBD, 4),
            .indexed_absolute_y = .init(0xB9, 4),
            .pre_indexed_indirect_zero_x = .init(0xA1, 6),
            .post_indexed_indirect_zero_y = .init(0xB1, 5),
        }),
    };
    pub const LDX = Instruction.Type{
        .mnemonic = "ldx",
        .description = "load X",
        .sub_instruction = .read,
        .implicit_target = .x,
        .operation_type = .read,
        .available_modes = .init(.{
            .immediate = .init(0xA2, 2),
            .zero = .init(0xA6, 3),
            .indexed_zero_y = .init(0xB6, 4),
            .absolute = .init(0xAE, 4),
            .indexed_absolute_y = .init(0xBE, 4),
        }),
    };
    pub const LDY = Instruction.Type{
        .mnemonic = "ldy",
        .description = "load Y",
        .sub_instruction = .read,
        .implicit_target = .y,
        .operation_type = .read,
        .available_modes = .init(.{
            .immediate = .init(0xA0, 2),
            .zero = .init(0xA4, 3),
            .indexed_zero_x = .init(0xB4, 4),
            .absolute = .init(0xAC, 4),
            .indexed_absolute_x = .init(0xBC, 4),
        }),
    };
    pub const LSR = Instruction.Type{
        .mnemonic = "lsr",
        .description = "logical shift right",
        .sub_instruction = .shift_right,
        .implicit_target = .a,
        .operation_type = .rmw,
        .available_modes = .init(.{
            .implicit = .init(0x4A, 2),
            .zero = .init(0x46, 5),
            .indexed_zero_x = .init(0x56, 6),
            .absolute = .init(0x4E, 6),
            .indexed_absolute_x = .init(0x5E, 7),
        }),
    };
    pub const NOP = Instruction.Type{
        .mnemonic = "nop",
        .description = "no operation",
        .sub_instruction = .noop,
        .operation_type = .read,
        .available_modes = .init(.{
            .implicit = .init(0xEA, 2),
        }),
    };
    pub const ORA = Instruction.Type{
        .mnemonic = "ora",
        .description = "or with accumulator",
        .sub_instruction = .bitwise_or,
        .implicit_target = .a,
        .operation_type = .read,
        .available_modes = .init(.{
            .immediate = .init(0x09, 2),
            .zero = .init(0x05, 3),
            .indexed_zero_x = .init(0x15, 4),
            .absolute = .init(0x0D, 4),
            .indexed_absolute_x = .init(0x1D, 4),
            .indexed_absolute_y = .init(0x19, 4),
            .pre_indexed_indirect_zero_x = .init(0x01, 6),
            .post_indexed_indirect_zero_y = .init(0x11, 5),
        }),
    };
    pub const PHA = Instruction.Type{
        .mnemonic = "pha",
        .description = "push accumulator",
        .operation_type = .stack_push,
        .sub_instruction = .{ .write_no_set_flags = .{ .src = .a } },
        .implicit_target = .db,
        .available_modes = .init(.{
            .implicit = .init(0x48, 3),
        }),
    };
    pub const PHP = Instruction.Type{
        .mnemonic = "php",
        .description = "push processor status (SR)",
        .operation_type = .stack_push,
        .sub_instruction = .{ .write_no_set_flags = .{ .src = .sr } },
        .implicit_target = .db,
        .available_modes = .init(.{
            .implicit = .init(0x08, 3),
        }),
    };
    pub const PLA = Instruction.Type{
        .mnemonic = "pla",
        .description = "pull accumulator",
        .operation_type = .stack_pull,
        .sub_instruction = .read,
        .implicit_target = .a,
        .available_modes = .init(.{
            .implicit = .init(0x68, 4),
        }),
    };
    pub const PLP = Instruction.Type{
        .mnemonic = "plp",
        .description = "pull processor status (SR)",
        .operation_type = .stack_pull,
        .sub_instruction = .read,
        .implicit_target = .sr,
        .available_modes = .init(.{
            .implicit = .init(0x28, 4),
        }),
    };
    pub const ROL = Instruction.Type{
        .mnemonic = "rol",
        .description = "rotate left",
        .sub_instruction = .rotate_left,
        .implicit_target = .a,
        .operation_type = .rmw,
        .available_modes = .init(.{
            .implicit = .init(0x2A, 2),
            .zero = .init(0x26, 5),
            .indexed_zero_x = .init(0x36, 6),
            .absolute = .init(0x2E, 6),
            .indexed_absolute_x = .init(0x3E, 7),
        }),
    };
    pub const ROR = Instruction.Type{
        .mnemonic = "ror",
        .description = "rotate right",
        .sub_instruction = .rotate_right,
        .implicit_target = .a,
        .operation_type = .rmw,
        .available_modes = .init(.{
            .implicit = .init(0x6A, 2),
            .zero = .init(0x66, 5),
            .indexed_zero_x = .init(0x76, 6),
            .absolute = .init(0x6E, 6),
            .indexed_absolute_x = .init(0x7E, 7),
        }),
    };
    pub const RTI = Instruction.Type{
        .mnemonic = "rti",
        .description = "return from interrupt",
        .operation_type = .rti,
        .available_modes = .init(.{
            .implicit = .init(0x40, 6),
        }),
    };
    pub const RTS = Instruction.Type{
        .mnemonic = "rts",
        .description = "return from subroutine",
        .operation_type = .rts,
        .available_modes = .init(.{
            .implicit = .init(0x60, 6),
        }),
    };
    pub const SBC = Instruction.Type{
        .mnemonic = "sbc",
        .description = "subtract with carry",
        .operation_type = .read,
        .sub_instruction = .sub_with_carry,
        .implicit_target = .a,
        .available_modes = .init(.{
            .immediate = .init(0xE9, 2),
            .zero = .init(0xE5, 3),
            .indexed_zero_x = .init(0xF5, 4),
            .absolute = .init(0xED, 4),
            .indexed_absolute_x = .init(0xFD, 4),
            .indexed_absolute_y = .init(0xF9, 4),
            .pre_indexed_indirect_zero_x = .init(0xE1, 6),
            .post_indexed_indirect_zero_y = .init(0xF1, 5),
        }),
    };
    pub const SEC = Instruction.Type{
        .mnemonic = "sec",
        .description = "set carry",
        .operation_type = .read,
        .sub_instruction = .set_flag,
        .implicit_target = .c,
        .available_modes = .init(.{
            .implicit = .init(0x38, 2),
        }),
    };
    pub const SED = Instruction.Type{
        .mnemonic = "sed",
        .description = "set decimal",
        .operation_type = .read,
        .sub_instruction = .set_flag,
        .implicit_target = .d,
        .available_modes = .init(.{
            .implicit = .init(0xF8, 2),
        }),
    };
    pub const SEI = Instruction.Type{
        .mnemonic = "sei",
        .description = "set interrupt disable",
        .operation_type = .read,
        .sub_instruction = .set_flag,
        .implicit_target = .i,
        .available_modes = .init(.{
            .implicit = .init(0x78, 2),
        }),
    };
    pub const STA = Instruction.Type{
        .mnemonic = "sta",
        .description = "store accumulator",
        .sub_instruction = .{ .write_no_set_flags = .{ .src = .a } },
        .operation_type = .store,
        .implicit_target = .db,
        .available_modes = .init(.{
            .zero = .init(0x85, 3),
            .indexed_zero_x = .init(0x95, 4),
            .absolute = .init(0x8D, 4),
            .indexed_absolute_x = .init(0x9D, 5),
            .indexed_absolute_y = .init(0x99, 5),
            .pre_indexed_indirect_zero_x = .init(0x81, 6),
            .post_indexed_indirect_zero_y = .init(0x91, 6),
        }),
    };
    pub const STX = Instruction.Type{
        .mnemonic = "stx",
        .description = "store X",
        .sub_instruction = .{ .write_no_set_flags = .{ .src = .x } },
        .operation_type = .store,
        .implicit_target = .db,
        .available_modes = .init(.{
            .zero = .init(0x86, 3),
            .indexed_zero_y = .init(0x96, 4),
            .absolute = .init(0x8E, 4),
        }),
    };
    pub const STY = Instruction.Type{
        .mnemonic = "sty",
        .description = "store Y",
        .sub_instruction = .{ .write_no_set_flags = .{ .src = .y } },
        .operation_type = .store,
        .implicit_target = .db,
        .available_modes = .init(.{
            .zero = .init(0x84, 3),
            .indexed_zero_x = .init(0x94, 4),
            .absolute = .init(0x8C, 4),
        }),
    };
    pub const TAX = Instruction.Type{
        .mnemonic = "tax",
        .description = "transfer accumulator to X",
        .sub_instruction = .{ .write = .{ .src = .a } },
        .operation_type = .read,
        .implicit_target = .x,
        .available_modes = .init(.{
            .implicit = .init(0xAA, 2),
        }),
    };
    pub const TAY = Instruction.Type{
        .mnemonic = "tay",
        .description = "transfer accumulator to Y",
        .sub_instruction = .{ .write = .{ .src = .a } },
        .operation_type = .read,
        .implicit_target = .y,
        .available_modes = .init(.{
            .implicit = .init(0xA8, 2),
        }),
    };
    pub const TSX = Instruction.Type{
        .mnemonic = "tsx",
        .description = "transfer stack pointer to X",
        .sub_instruction = .{ .write = .{ .src = .s } },
        .operation_type = .read,
        .implicit_target = .x,
        .available_modes = .init(.{
            .implicit = .init(0xBA, 2),
        }),
    };
    pub const TXA = Instruction.Type{
        .mnemonic = "txa",
        .description = "transfer X to accumulator",
        .sub_instruction = .{ .write = .{ .src = .x } },
        .operation_type = .read,
        .implicit_target = .a,
        .available_modes = .init(.{
            .implicit = .init(0x8A, 2),
        }),
    };
    pub const TXS = Instruction.Type{
        .mnemonic = "txs",
        .description = "transfer X to stack pointer",
        .sub_instruction = .{ .write_no_set_flags = .{ .src = .x } },
        .operation_type = .read,
        .implicit_target = .s,
        .available_modes = .init(.{
            .implicit = .init(0x9A, 2),
        }),
    };
    pub const TYA = Instruction.Type{
        .mnemonic = "tya",
        .description = "transfer Y to accumulator",
        .sub_instruction = .{ .write = .{ .src = .y } },
        .operation_type = .read,
        .implicit_target = .a,
        .available_modes = .init(.{
            .implicit = .init(0x98, 2),
        }),
    };
};

const n_max_opcodes = 0x100;
const opcode_mode_table: [n_max_opcodes]?Instruction.AddressingModeTag = brk: {
    var ot: [n_max_opcodes]?Instruction.AddressingModeTag = .{null} ** n_max_opcodes;
    ot[0x00] = .immediate;
    ot[0x01] = .pre_indexed_indirect_zero_x;
    ot[0x05] = .zero;
    ot[0x06] = .zero;
    ot[0x08] = .implicit;
    ot[0x09] = .immediate;
    ot[0x0A] = .implicit;
    ot[0x0D] = .absolute;
    ot[0x0E] = .absolute;
    ot[0x10] = .relative;
    ot[0x11] = .post_indexed_indirect_zero_y;
    ot[0x15] = .indexed_zero_x;
    ot[0x16] = .indexed_zero_x;
    ot[0x18] = .implicit;
    ot[0x19] = .indexed_absolute_y;
    ot[0x1D] = .indexed_absolute_x;
    ot[0x1E] = .indexed_absolute_x;
    ot[0x20] = .absolute;
    ot[0x21] = .pre_indexed_indirect_zero_x;
    ot[0x24] = .zero;
    ot[0x25] = .zero;
    ot[0x26] = .zero;
    ot[0x28] = .implicit;
    ot[0x29] = .immediate;
    ot[0x2A] = .implicit;
    ot[0x2C] = .absolute;
    ot[0x2D] = .absolute;
    ot[0x2E] = .absolute;
    ot[0x30] = .relative;
    ot[0x31] = .post_indexed_indirect_zero_y;
    ot[0x35] = .indexed_zero_x;
    ot[0x36] = .indexed_zero_x;
    ot[0x38] = .implicit;
    ot[0x39] = .indexed_absolute_y;
    ot[0x3D] = .indexed_absolute_x;
    ot[0x3E] = .indexed_absolute_x;
    ot[0x40] = .implicit;
    ot[0x41] = .pre_indexed_indirect_zero_x;
    ot[0x45] = .zero;
    ot[0x46] = .zero;
    ot[0x48] = .implicit;
    ot[0x49] = .immediate;
    ot[0x4A] = .implicit;
    ot[0x4C] = .absolute;
    ot[0x4D] = .absolute;
    ot[0x4E] = .absolute;
    ot[0x50] = .relative;
    ot[0x51] = .post_indexed_indirect_zero_y;
    ot[0x55] = .indexed_zero_x;
    ot[0x56] = .indexed_zero_x;
    ot[0x58] = .implicit;
    ot[0x59] = .indexed_absolute_y;
    ot[0x5D] = .indexed_absolute_x;
    ot[0x5E] = .indexed_absolute_x;
    ot[0x60] = .implicit;
    ot[0x61] = .pre_indexed_indirect_zero_x;
    ot[0x65] = .zero;
    ot[0x66] = .zero;
    ot[0x68] = .implicit;
    ot[0x69] = .immediate;
    ot[0x6A] = .implicit;
    ot[0x6C] = .indirect_absolute;
    ot[0x6D] = .absolute;
    ot[0x6E] = .absolute;
    ot[0x70] = .relative;
    ot[0x71] = .post_indexed_indirect_zero_y;
    ot[0x75] = .indexed_zero_x;
    ot[0x76] = .indexed_zero_x;
    ot[0x78] = .implicit;
    ot[0x79] = .indexed_absolute_y;
    ot[0x7D] = .indexed_absolute_x;
    ot[0x7E] = .indexed_absolute_x;
    ot[0x81] = .pre_indexed_indirect_zero_x;
    ot[0x84] = .zero;
    ot[0x85] = .zero;
    ot[0x86] = .zero;
    ot[0x88] = .implicit;
    ot[0x8A] = .implicit;
    ot[0x8C] = .absolute;
    ot[0x8D] = .absolute;
    ot[0x8E] = .absolute;
    ot[0x90] = .relative;
    ot[0x91] = .post_indexed_indirect_zero_y;
    ot[0x94] = .indexed_zero_x;
    ot[0x95] = .indexed_zero_x;
    ot[0x96] = .indexed_zero_y;
    ot[0x98] = .implicit;
    ot[0x99] = .indexed_absolute_y;
    ot[0x9A] = .implicit;
    ot[0x9D] = .indexed_absolute_x;
    ot[0xA0] = .immediate;
    ot[0xA1] = .pre_indexed_indirect_zero_x;
    ot[0xA2] = .immediate;
    ot[0xA4] = .zero;
    ot[0xA5] = .zero;
    ot[0xA6] = .zero;
    ot[0xA8] = .implicit;
    ot[0xA9] = .immediate;
    ot[0xAA] = .implicit;
    ot[0xAC] = .absolute;
    ot[0xAD] = .absolute;
    ot[0xAE] = .absolute;
    ot[0xB0] = .relative;
    ot[0xB1] = .post_indexed_indirect_zero_y;
    ot[0xB4] = .indexed_zero_x;
    ot[0xB5] = .indexed_zero_x;
    ot[0xB6] = .indexed_zero_y;
    ot[0xB8] = .implicit;
    ot[0xB9] = .indexed_absolute_y;
    ot[0xBA] = .implicit;
    ot[0xBC] = .indexed_absolute_x;
    ot[0xBD] = .indexed_absolute_x;
    ot[0xBE] = .indexed_absolute_y;
    ot[0xC0] = .immediate;
    ot[0xC1] = .pre_indexed_indirect_zero_x;
    ot[0xC4] = .zero;
    ot[0xC5] = .zero;
    ot[0xC6] = .zero;
    ot[0xC8] = .implicit;
    ot[0xC9] = .immediate;
    ot[0xCA] = .implicit;
    ot[0xCC] = .absolute;
    ot[0xCD] = .absolute;
    ot[0xCE] = .absolute;
    ot[0xD0] = .relative;
    ot[0xD1] = .post_indexed_indirect_zero_y;
    ot[0xD5] = .indexed_zero_x;
    ot[0xD6] = .indexed_zero_x;
    ot[0xD8] = .implicit;
    ot[0xD9] = .indexed_absolute_y;
    ot[0xDD] = .indexed_absolute_x;
    ot[0xDE] = .indexed_absolute_x;
    ot[0xE0] = .immediate;
    ot[0xE1] = .pre_indexed_indirect_zero_x;
    ot[0xE4] = .zero;
    ot[0xE5] = .zero;
    ot[0xE6] = .zero;
    ot[0xE8] = .implicit;
    ot[0xE9] = .immediate;
    ot[0xEA] = .implicit;
    ot[0xEB] = .immediate;
    ot[0xEC] = .absolute;
    ot[0xED] = .absolute;
    ot[0xEE] = .absolute;
    ot[0xF0] = .relative;
    ot[0xF1] = .post_indexed_indirect_zero_y;
    ot[0xF5] = .indexed_zero_x;
    ot[0xF6] = .indexed_zero_x;
    ot[0xF8] = .implicit;
    ot[0xF9] = .indexed_absolute_y;
    ot[0xFD] = .indexed_absolute_x;
    ot[0xFE] = .indexed_absolute_x;
    break :brk ot;
};

pub const opcode_type_table: [n_max_opcodes]?*const Instruction.Type = brk: {
    var ot: [n_max_opcodes]?*const Instruction.Type = .{null} ** n_max_opcodes;
    ot[0x69] = &Instructions.ADC;
    ot[0x65] = &Instructions.ADC;
    ot[0x75] = &Instructions.ADC;
    ot[0x6D] = &Instructions.ADC;
    ot[0x7D] = &Instructions.ADC;
    ot[0x79] = &Instructions.ADC;
    ot[0x61] = &Instructions.ADC;
    ot[0x71] = &Instructions.ADC;
    ot[0x29] = &Instructions.AND;
    ot[0x25] = &Instructions.AND;
    ot[0x35] = &Instructions.AND;
    ot[0x2D] = &Instructions.AND;
    ot[0x3D] = &Instructions.AND;
    ot[0x39] = &Instructions.AND;
    ot[0x21] = &Instructions.AND;
    ot[0x31] = &Instructions.AND;
    ot[0x0A] = &Instructions.ASL;
    ot[0x06] = &Instructions.ASL;
    ot[0x16] = &Instructions.ASL;
    ot[0x0E] = &Instructions.ASL;
    ot[0x1E] = &Instructions.ASL;
    ot[0x90] = &Instructions.BCC;
    ot[0xB0] = &Instructions.BCS;
    ot[0xF0] = &Instructions.BEQ;
    ot[0x24] = &Instructions.BIT;
    ot[0x2C] = &Instructions.BIT;
    ot[0x30] = &Instructions.BMI;
    ot[0xD0] = &Instructions.BNE;
    ot[0x10] = &Instructions.BPL;
    ot[0x00] = &Instructions.BRK;
    ot[0x50] = &Instructions.BVC;
    ot[0x70] = &Instructions.BVS;
    ot[0x18] = &Instructions.CLC;
    ot[0xD8] = &Instructions.CLD;
    ot[0x58] = &Instructions.CLI;
    ot[0xB8] = &Instructions.CLV;
    ot[0xC9] = &Instructions.CMP;
    ot[0xC5] = &Instructions.CMP;
    ot[0xD5] = &Instructions.CMP;
    ot[0xCD] = &Instructions.CMP;
    ot[0xDD] = &Instructions.CMP;
    ot[0xD9] = &Instructions.CMP;
    ot[0xC1] = &Instructions.CMP;
    ot[0xD1] = &Instructions.CMP;
    ot[0xE0] = &Instructions.CPX;
    ot[0xE4] = &Instructions.CPX;
    ot[0xEC] = &Instructions.CPX;
    ot[0xC0] = &Instructions.CPY;
    ot[0xC4] = &Instructions.CPY;
    ot[0xCC] = &Instructions.CPY;
    ot[0xC6] = &Instructions.DEC;
    ot[0xD6] = &Instructions.DEC;
    ot[0xCE] = &Instructions.DEC;
    ot[0xDE] = &Instructions.DEC;
    ot[0xCA] = &Instructions.DEX;
    ot[0x88] = &Instructions.DEY;
    ot[0x49] = &Instructions.EOR;
    ot[0x45] = &Instructions.EOR;
    ot[0x55] = &Instructions.EOR;
    ot[0x4D] = &Instructions.EOR;
    ot[0x5D] = &Instructions.EOR;
    ot[0x59] = &Instructions.EOR;
    ot[0x41] = &Instructions.EOR;
    ot[0x51] = &Instructions.EOR;
    ot[0xE6] = &Instructions.INC;
    ot[0xF6] = &Instructions.INC;
    ot[0xEE] = &Instructions.INC;
    ot[0xFE] = &Instructions.INC;
    ot[0xE8] = &Instructions.INX;
    ot[0xC8] = &Instructions.INY;
    ot[0x4C] = &Instructions.JMP;
    ot[0x6C] = &Instructions.JMP;
    ot[0x20] = &Instructions.JSR;
    ot[0xA9] = &Instructions.LDA;
    ot[0xA5] = &Instructions.LDA;
    ot[0xB5] = &Instructions.LDA;
    ot[0xAD] = &Instructions.LDA;
    ot[0xBD] = &Instructions.LDA;
    ot[0xB9] = &Instructions.LDA;
    ot[0xA1] = &Instructions.LDA;
    ot[0xB1] = &Instructions.LDA;
    ot[0xA2] = &Instructions.LDX;
    ot[0xA6] = &Instructions.LDX;
    ot[0xB6] = &Instructions.LDX;
    ot[0xAE] = &Instructions.LDX;
    ot[0xBE] = &Instructions.LDX;
    ot[0xA0] = &Instructions.LDY;
    ot[0xA4] = &Instructions.LDY;
    ot[0xB4] = &Instructions.LDY;
    ot[0xAC] = &Instructions.LDY;
    ot[0xBC] = &Instructions.LDY;
    ot[0x4A] = &Instructions.LSR;
    ot[0x46] = &Instructions.LSR;
    ot[0x56] = &Instructions.LSR;
    ot[0x4E] = &Instructions.LSR;
    ot[0x5E] = &Instructions.LSR;
    ot[0xEA] = &Instructions.NOP;
    ot[0x09] = &Instructions.ORA;
    ot[0x05] = &Instructions.ORA;
    ot[0x15] = &Instructions.ORA;
    ot[0x0D] = &Instructions.ORA;
    ot[0x1D] = &Instructions.ORA;
    ot[0x19] = &Instructions.ORA;
    ot[0x01] = &Instructions.ORA;
    ot[0x11] = &Instructions.ORA;
    ot[0x48] = &Instructions.PHA;
    ot[0x08] = &Instructions.PHP;
    ot[0x68] = &Instructions.PLA;
    ot[0x28] = &Instructions.PLP;
    ot[0x2A] = &Instructions.ROL;
    ot[0x26] = &Instructions.ROL;
    ot[0x36] = &Instructions.ROL;
    ot[0x2E] = &Instructions.ROL;
    ot[0x3E] = &Instructions.ROL;
    ot[0x6A] = &Instructions.ROR;
    ot[0x66] = &Instructions.ROR;
    ot[0x76] = &Instructions.ROR;
    ot[0x6E] = &Instructions.ROR;
    ot[0x7E] = &Instructions.ROR;
    ot[0x40] = &Instructions.RTI;
    ot[0x60] = &Instructions.RTS;
    ot[0xE9] = &Instructions.SBC;
    ot[0xE5] = &Instructions.SBC;
    ot[0xEB] = &Instructions.SBC;
    ot[0xF5] = &Instructions.SBC;
    ot[0xED] = &Instructions.SBC;
    ot[0xFD] = &Instructions.SBC;
    ot[0xF9] = &Instructions.SBC;
    ot[0xE1] = &Instructions.SBC;
    ot[0xF1] = &Instructions.SBC;
    ot[0x38] = &Instructions.SEC;
    ot[0xF8] = &Instructions.SED;
    ot[0x78] = &Instructions.SEI;
    ot[0x85] = &Instructions.STA;
    ot[0x95] = &Instructions.STA;
    ot[0x8D] = &Instructions.STA;
    ot[0x9D] = &Instructions.STA;
    ot[0x99] = &Instructions.STA;
    ot[0x81] = &Instructions.STA;
    ot[0x91] = &Instructions.STA;
    ot[0x86] = &Instructions.STX;
    ot[0x96] = &Instructions.STX;
    ot[0x8E] = &Instructions.STX;
    ot[0x84] = &Instructions.STY;
    ot[0x94] = &Instructions.STY;
    ot[0x8C] = &Instructions.STY;
    ot[0xAA] = &Instructions.TAX;
    ot[0xA8] = &Instructions.TAY;
    ot[0xBA] = &Instructions.TSX;
    ot[0x8A] = &Instructions.TXA;
    ot[0x9A] = &Instructions.TXS;
    ot[0x98] = &Instructions.TYA;
    break :brk ot;
};

fn getInstructionsAsBytes(instructions: []const Instruction) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;

    for (instructions) |instruction| switch (instruction.mode) {
        inline else => |s| {
            field: inline for (comptime std.meta.fields(@TypeOf(s))) |field| {
                if (field.type == void) continue :field;

                const field_value = @field(s, field.name);

                try bytes.appendSlice(std.testing.allocator, std.mem.asBytes(&field_value));
            }
        },
    };

    return bytes.toOwnedSlice(std.testing.allocator);
}

test "populating instructions" {
    @setEvalBranchQuota(100000);

    const instructions: []const Instruction = &.{
        .ASL(.implicit, {}),
        .BRK(.immediate, 0x42),
        .CLC(.implicit, {}),
        .CLD(.implicit, {}),
        .CLI(.implicit, {}),
        .CLV(.implicit, {}),
        .DEX(.implicit, {}),
        .DEY(.implicit, {}),
        .INX(.implicit, {}),
        .INY(.implicit, {}),
        .LSR(.implicit, {}),
        .NOP(.implicit, {}),
        .PHA(.implicit, {}),
        .PHP(.implicit, {}),
        .PLA(.implicit, {}),
        .PLP(.implicit, {}),
        .ROL(.implicit, {}),
        .ROR(.implicit, {}),
        .RTI(.implicit, {}),
        .RTS(.implicit, {}),
        .SEC(.implicit, {}),
        .SED(.implicit, {}),
        .SEI(.implicit, {}),
        .TAX(.implicit, {}),
        .TAY(.implicit, {}),
        .TSX(.implicit, {}),
        .TXA(.implicit, {}),
        .TXS(.implicit, {}),
        .TYA(.implicit, {}),
        .ADC(.absolute, .fromInt(0xF000)),
        .ADC(.immediate, 1),
        .ADC(.indexed_absolute_x, .fromInt(0xF000)),
        .ADC(.indexed_absolute_y, .fromInt(0xF000)),
        .ADC(.indexed_zero_x, 0),
        .ADC(.pre_indexed_indirect_zero_x, 0),
        .ADC(.post_indexed_indirect_zero_y, 0),
        .ADC(.zero, 0),
        .AND(.absolute, .fromInt(0xF000)),
        .AND(.immediate, 1),
        .AND(.indexed_absolute_x, .fromInt(0xF000)),
        .AND(.indexed_absolute_y, .fromInt(0xF000)),
        .AND(.indexed_zero_x, 0),
        .AND(.pre_indexed_indirect_zero_x, 0),
        .AND(.post_indexed_indirect_zero_y, 0),
        .AND(.zero, 0),
        .ASL(.absolute, .fromInt(0xF000)),
        .ASL(.indexed_absolute_x, .fromInt(0xF000)),
        .ASL(.indexed_zero_x, 0),
        .ASL(.zero, 0),
        .BCC(.relative, 0x0),
        .BCS(.relative, -0x2),
        .BEQ(.relative, -0x4),
        .BIT(.absolute, .fromInt(0xF000)),
        .BIT(.zero, 0),
        .BMI(.relative, -0x8),
        .BNE(.relative, -0x6),
        .BPL(.relative, -0x10),
        .BVC(.relative, -0x12),
        .BVS(.relative, -0x14),
        .CMP(.absolute, .fromInt(0xF000)),
        .CMP(.immediate, 1),
        .CMP(.indexed_absolute_x, .fromInt(0xF000)),
        .CMP(.indexed_absolute_y, .fromInt(0xF000)),
        .CMP(.indexed_zero_x, 0),
        .CMP(.pre_indexed_indirect_zero_x, 0),
        .CMP(.post_indexed_indirect_zero_y, 0),
        .CMP(.zero, 0),
        .CPX(.absolute, .fromInt(0xF000)),
        .CPX(.immediate, 1),
        .CPX(.zero, 0),
        .CPY(.absolute, .fromInt(0xF000)),
        .CPY(.immediate, 1),
        .CPY(.zero, 0),
        .DEC(.absolute, .fromInt(0xF000)),
        .DEC(.indexed_absolute_x, .fromInt(0xF000)),
        .DEC(.indexed_zero_x, 0),
        .DEC(.zero, 0),
        .EOR(.absolute, .fromInt(0xF000)),
        .EOR(.immediate, 1),
        .EOR(.indexed_absolute_x, .fromInt(0xF000)),
        .EOR(.indexed_absolute_y, .fromInt(0xF000)),
        .EOR(.indexed_zero_x, 0),
        .EOR(.pre_indexed_indirect_zero_x, 0),
        .EOR(.post_indexed_indirect_zero_y, 0),
        .EOR(.zero, 0),
        .INC(.absolute, .fromInt(0xF000)),
        .INC(.indexed_absolute_x, .fromInt(0xF000)),
        .INC(.indexed_zero_x, 0),
        .INC(.zero, 0),
        .JMP(.absolute, .fromInt(0xF000)),
        .JMP(.indirect_absolute, .fromInt(0xF000)),
        .JSR(.absolute, .fromInt(0x8123)),
        .LDA(.absolute, .fromInt(0xF000)),
        .LDA(.immediate, 1),
        .LDA(.indexed_absolute_x, .fromInt(0xF000)),
        .LDA(.indexed_absolute_y, .fromInt(0xF000)),
        .LDA(.indexed_zero_x, 0),
        .LDA(.pre_indexed_indirect_zero_x, 0),
        .LDA(.post_indexed_indirect_zero_y, 0),
        .LDA(.zero, 0),
        .LDX(.absolute, .fromInt(0xF000)),
        .LDX(.immediate, 1),
        .LDX(.indexed_absolute_y, .fromInt(0xF000)),
        .LDX(.indexed_zero_y, 0),
        .LDX(.zero, 0),
        .LDY(.absolute, .fromInt(0xF000)),
        .LDY(.immediate, 1),
        .LDY(.indexed_absolute_x, .fromInt(0xF000)),
        .LDY(.indexed_zero_x, 0),
        .LDY(.zero, 0),
        .LSR(.absolute, .fromInt(0xF000)),
        .LSR(.indexed_absolute_x, .fromInt(0xF000)),
        .LSR(.indexed_zero_x, 0),
        .LSR(.zero, 0),
        .ORA(.absolute, .fromInt(0xF000)),
        .ORA(.immediate, 1),
        .ORA(.indexed_absolute_x, .fromInt(0xF000)),
        .ORA(.indexed_absolute_y, .fromInt(0xF000)),
        .ORA(.indexed_zero_x, 0),
        .ORA(.pre_indexed_indirect_zero_x, 0),
        .ORA(.post_indexed_indirect_zero_y, 0),
        .ORA(.zero, 0),
        .ROL(.absolute, .fromInt(0xF000)),
        .ROL(.indexed_absolute_x, .fromInt(0xF000)),
        .ROL(.indexed_zero_x, 0),
        .ROL(.zero, 0),
        .ROR(.absolute, .fromInt(0xF000)),
        .ROR(.indexed_absolute_x, .fromInt(0xF000)),
        .ROR(.indexed_zero_x, 0),
        .ROR(.zero, 0),
        .SBC(.absolute, .fromInt(0xF000)),
        .SBC(.immediate, 1),
        .SBC(.indexed_absolute_x, .fromInt(0xF000)),
        .SBC(.indexed_absolute_y, .fromInt(0xF000)),
        .SBC(.indexed_zero_x, 0),
        .SBC(.pre_indexed_indirect_zero_x, 0),
        .SBC(.post_indexed_indirect_zero_y, 0),
        .SBC(.zero, 0),
        .STA(.absolute, .fromInt(0xF000)),
        .STA(.indexed_absolute_x, .fromInt(0xF000)),
        .STA(.indexed_absolute_y, .fromInt(0xF000)),
        .STA(.indexed_zero_x, 0),
        .STA(.pre_indexed_indirect_zero_x, 0),
        .STA(.post_indexed_indirect_zero_y, 0),
        .STA(.zero, 0),
        .STX(.absolute, .fromInt(0xF000)),
        .STX(.indexed_zero_y, 0),
        .STX(.zero, 0),
        .STY(.absolute, .fromInt(0xF000)),
        .STY(.indexed_zero_x, 0),
        .STY(.zero, 0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x0A, // ASL
        0x00, // BRK
        0x42, // brk arg
        0x18, // CLC
        0xD8, // CLD
        0x58, // CLI
        0xB8, // CLV
        0xCA, // DEX
        0x88, // DEY
        0xE8, // INX
        0xC8, // INY
        0x4A, // LSR
        0xEA, // NOP
        0x48, // PHA
        0x08, // PHP
        0x68, // PLA
        0x28, // PLP
        0x2A, // ROL
        0x6A, // ROR
        0x40, // RTI
        0x60, // RTS
        0x38, // SEC
        0xF8, // SED
        0x78, // SEI
        0xAA, // TAX
        0xA8, // TAY
        0xBA, // TSX
        0x8A, // TXA
        0x9A, // TXS
        0x98, // TYA
        0x6D, // ADC absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x69, // ADC immediate 0x01
        0x01,
        0x7D, // ADC indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x79, // ADC indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0x75, // ADC indexed_zero_x 0x00
        0x00,
        0x61, // ADC pre_indexed_indirect_zero_x 0x00
        0x00,
        0x71, // ADC post_indexed_indirect_zero_y 0x00
        0x00,
        0x65, // ADC zero 0x00
        0x00,
        0x2D, // AND absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x29, // AND immediate 0x01
        0x01,
        0x3D, // AND indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x39, // AND indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0x35, // AND indexed_zero_x 0x00
        0x00,
        0x21, // AND pre_indexed_indirect_zero_x 0x00
        0x00,
        0x31, // AND post_indexed_indirect_zero_y 0x00
        0x00,
        0x25, // AND zero 0x00
        0x00,
        0x0E, // ASL absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x1E, // ASL indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x16, // ASL indexed_zero_x 0x00
        0x00,
        0x06, // ASL zero 0x00
        0x00,
        0x90, // BCC relative 0x0
        0xFE,
        0xB0, // BCS relative -0x2
        0xFC,
        0xF0, // BEQ relative -0x4
        0xFA,
        0x2C, // BIT absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x24, // BIT zero 0x00
        0x00,
        0x30, // BMI relative -0x8
        0xF6,
        0xD0, // BNE relative -0x6
        0xF8,
        0x10, // BPL relative -0x10
        0xEE,
        0x50, // BVC relative -0x12
        0xEC,
        0x70, // BVS relative -0x14
        0xEA,
        0xCD, // CMP absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xC9, // CMP immediate 0x01
        0x01,
        0xDD, // CMP indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0xD9, // CMP indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0xD5, // CMP indexed_zero_x 0x00
        0x00,
        0xC1, // CMP pre_indexed_indirect_zero_x 0x00
        0x00,
        0xD1, // CMP post_indexed_indirect_zero_y 0x00
        0x00,
        0xC5, // CMP zero 0x00
        0x00,
        0xEC, // CPX absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xE0, // CPX immediate 0x01
        0x01,
        0xE4, // CPX zero 0x00
        0x00,
        0xCC, // CPY absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xC0, // CPY immediate 0x01
        0x01,
        0xC4, // CPY zero 0x00
        0x00,
        0xCE, // DEC absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xDE, // DEC indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0xD6, // DEC indexed_zero_x 0x00
        0x00,
        0xC6, // DEC zero 0x00
        0x00,
        0x4D, // EOR absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x49, // EOR immediate 0x01
        0x01,
        0x5D, // EOR indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x59, // EOR indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0x55, // EOR indexed_zero_x 0x00
        0x00,
        0x41, // EOR pre_indexed_indirect_zero_x 0x00
        0x00,
        0x51, // EOR post_indexed_indirect_zero_y 0x00
        0x00,
        0x45, // EOR zero 0x00
        0x00,
        0xEE, // INC absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xFE, // INC indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0xF6, // INC indexed_zero_x 0x00
        0x00,
        0xE6, // INC zero 0x00
        0x00,
        0x4C, // JMP absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x6C, // JMP indirect_absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x20, // JSR absolute 0x8123
        0x23,
        0x81,
        0xAD, // LDA absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xA9, // LDA immediate 0x01
        0x01,
        0xBD, // LDA indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0xB9, // LDA indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0xB5, // LDA indexed_zero_x 0x00
        0x00,
        0xA1, // LDA pre_indexed_indirect_zero_x 0x00
        0x00,
        0xB1, // LDA post_indexed_indirect_zero_y 0x00
        0x00,
        0xA5, // LDA zero 0x00
        0x00,
        0xAE, // LDX absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xA2, // LDX immediate 0x01
        0x01,
        0xBE, // LDX indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0xB6, // LDX indexed_zero_y 0x00
        0x00,
        0xA6, // LDX zero 0x00
        0x00,
        0xAC, // LDY absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xA0, // LDY immediate 0x01
        0x01,
        0xBC, // LDY indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0xB4, // LDY indexed_zero_x 0x00
        0x00,
        0xA4, // LDY zero 0x00
        0x00,
        0x4E, // LSR absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x5E, // LSR indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x56, // LSR indexed_zero_x 0x00
        0x00,
        0x46, // LSR zero 0x00
        0x00,
        0x0D, // ORA absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x09, // ORA immediate 0x01
        0x01,
        0x1D, // ORA indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x19, // ORA indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0x15, // ORA indexed_zero_x 0x00
        0x00,
        0x01, // ORA pre_indexed_indirect_zero_x 0x00
        0x00,
        0x11, // ORA post_indexed_indirect_zero_y 0x00
        0x00,
        0x05, // ORA zero 0x00
        0x00,
        0x2E, // ROL absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x3E, // ROL indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x36, // ROL indexed_zero_x 0x00
        0x00,
        0x26, // ROL zero 0x00
        0x00,
        0x6E, // ROR absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x7E, // ROR indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x76, // ROR indexed_zero_x 0x00
        0x00,
        0x66, // ROR zero 0x00
        0x00,
        0xED, // SBC absolute 0x00, 0xF0
        0x00,
        0xF0,
        0xE9, // SBC immediate 0x01
        0x01,
        0xFD, // SBC indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0xF9, // SBC indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0xF5, // SBC indexed_zero_x 0x00
        0x00,
        0xE1, // SBC pre_indexed_indirect_zero_x 0x00
        0x00,
        0xF1, // SBC post_indexed_indirect_zero_y 0x00
        0x00,
        0xE5, // SBC zero 0x00
        0x00,
        0x8D, // STA absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x9D, // STA indexed_absolute_x 0x00, 0xF0
        0x00,
        0xF0,
        0x99, // STA indexed_absolute_y 0x00, 0xF0
        0x00,
        0xF0,
        0x95, // STA indexed_zero_x 0x00
        0x00,
        0x81, // STA pre_indexed_indirect_zero_x 0x00
        0x00,
        0x91, // STA post_indexed_indirect_zero_y 0x00
        0x00,
        0x85, // STA zero 0x00
        0x00,
        0x8E, // STX absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x96, // STX indexed_zero_y 0x00
        0x00,
        0x86, // STX zero 0x00
        0x00,
        0x8C, // STY absolute 0x00, 0xF0
        0x00,
        0xF0,
        0x94, // STY indexed_zero_x 0x00
        0x00,
        0x84, // STY zero 0x00
        0x00,
    }), bytes);
}

test "generate instruction ASL implicit" {
    const instructions: []const Instruction = &.{
        .ASL(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x0A, // ASL
    }), bytes);
}

test "generate instruction BRK implicit" {
    const instructions: []const Instruction = &.{
        .BRK(.immediate, 0x42),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x00, // BRK
        0x42, // arg
    }), bytes);
}

test "generate instruction CLC implicit" {
    const instructions: []const Instruction = &.{
        .CLC(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x18, // CLC
    }), bytes);
}

test "generate instruction CLD implicit" {
    const instructions: []const Instruction = &.{
        .CLD(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xD8, // CLD
    }), bytes);
}

test "generate instruction CLI implicit" {
    const instructions: []const Instruction = &.{
        .CLI(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x58, // CLI
    }), bytes);
}

test "generate instruction CLV implicit" {
    const instructions: []const Instruction = &.{
        .CLV(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xB8, // CLV
    }), bytes);
}

test "generate instruction DEX implicit" {
    const instructions: []const Instruction = &.{
        .DEX(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xCA, // DEX
    }), bytes);
}

test "generate instruction DEY implicit" {
    const instructions: []const Instruction = &.{
        .DEY(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x88, // DEY
    }), bytes);
}

test "generate instruction INX implicit" {
    const instructions: []const Instruction = &.{
        .INX(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xE8, // INX
    }), bytes);
}

test "generate instruction INY implicit" {
    const instructions: []const Instruction = &.{
        .INY(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xC8, // INY
    }), bytes);
}

test "generate instruction LSR implicit" {
    const instructions: []const Instruction = &.{
        .LSR(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x4A, // LSR
    }), bytes);
}

test "generate instruction NOP implicit" {
    const instructions: []const Instruction = &.{
        .NOP(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xEA, // NOP
    }), bytes);
}

test "generate instruction PHA implicit" {
    const instructions: []const Instruction = &.{
        .PHA(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x48, // PHA
    }), bytes);
}

test "generate instruction PHP implicit" {
    const instructions: []const Instruction = &.{
        .PHP(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x08, // PHP
    }), bytes);
}

test "generate instruction PLA implicit" {
    const instructions: []const Instruction = &.{
        .PLA(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x68, // PLA
    }), bytes);
}

test "generate instruction PLP implicit" {
    const instructions: []const Instruction = &.{
        .PLP(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x28, // PLP
    }), bytes);
}

test "generate instruction ROL implicit" {
    const instructions: []const Instruction = &.{
        .ROL(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x2A, // ROL
    }), bytes);
}

test "generate instruction ROR implicit" {
    const instructions: []const Instruction = &.{
        .ROR(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x6A, // ROR
    }), bytes);
}

test "generate instruction RTI implicit" {
    const instructions: []const Instruction = &.{
        .RTI(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x40, // RTI
    }), bytes);
}

test "generate instruction RTS implicit" {
    const instructions: []const Instruction = &.{
        .RTS(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x60, // RTS
    }), bytes);
}

test "generate instruction SEC implicit" {
    const instructions: []const Instruction = &.{
        .SEC(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x38, // SEC
    }), bytes);
}

test "generate instruction SED implicit" {
    const instructions: []const Instruction = &.{
        .SED(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xF8, // SED
    }), bytes);
}

test "generate instruction SEI implicit" {
    const instructions: []const Instruction = &.{
        .SEI(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x78, // SEI
    }), bytes);
}

test "generate instruction TAX implicit" {
    const instructions: []const Instruction = &.{
        .TAX(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xAA, // TAX
    }), bytes);
}

test "generate instruction TAY implicit" {
    const instructions: []const Instruction = &.{
        .TAY(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xA8, // TAY
    }), bytes);
}

test "generate instruction TSX implicit" {
    const instructions: []const Instruction = &.{
        .TSX(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xBA, // TSX
    }), bytes);
}

test "generate instruction TXA implicit" {
    const instructions: []const Instruction = &.{
        .TXA(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x8A, // TXA
    }), bytes);
}

test "generate instruction TXS implicit" {
    const instructions: []const Instruction = &.{
        .TXS(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x9A, // TXS
    }), bytes);
}

test "generate instruction TYA implicit" {
    const instructions: []const Instruction = &.{
        .TYA(.implicit, {}),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x98, // TYA
    }), bytes);
}

test "generate instruction ADC absolute" {
    const instructions: []const Instruction = &.{
        .ADC(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x6D, // ADC absolute 0x00, 0xF0
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ADC indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .ADC(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x7D, // ADC indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ADC indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .ADC(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x79, // ADC indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction AND absolute" {
    const instructions: []const Instruction = &.{
        .AND(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x2D, // AND absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction AND indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .AND(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x3D, // AND indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction AND indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .AND(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x39, // AND indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ASL absolute" {
    const instructions: []const Instruction = &.{
        .ASL(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x0E, // ASL absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ASL indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .ASL(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x1E, // ASL indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction BIT absolute" {
    const instructions: []const Instruction = &.{
        .BIT(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x2C, // BIT absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction CMP absolute" {
    const instructions: []const Instruction = &.{
        .CMP(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xCD, // CMP absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction CMP indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .CMP(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xDD, // CMP indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction CMP indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .CMP(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xD9, // CMP indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction CPX absolute" {
    const instructions: []const Instruction = &.{
        .CPX(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xEC, // CPX absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction CPY absolute" {
    const instructions: []const Instruction = &.{
        .CPY(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xCC, // CPY absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction DEC absolute" {
    const instructions: []const Instruction = &.{
        .DEC(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xCE, // DEC absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction DEC indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .DEC(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xDE, // DEC indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction EOR absolute" {
    const instructions: []const Instruction = &.{
        .EOR(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x4D, // EOR absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction EOR indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .EOR(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x5D, // EOR indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction EOR indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .EOR(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x59, // EOR indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction INC absolute" {
    const instructions: []const Instruction = &.{
        .INC(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xEE, // INC absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction INC indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .INC(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xFE, // INC indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction JMP absolute" {
    const instructions: []const Instruction = &.{
        .JMP(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x4C, // JMP absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction JMP indirect_absolute" {
    const instructions: []const Instruction = &.{
        .JMP(.indirect_absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x6C, // JMP indirect_absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction JSR absolute" {
    const instructions: []const Instruction = &.{
        .JSR(.absolute, .fromInt(0x8123)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x20, // JSR absolute 0x8123
        //
        0x23,
        0x81,
    }), bytes);
}

test "generate instruction LDA absolute" {
    const instructions: []const Instruction = &.{
        .LDA(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xAD, // LDA absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction LDA indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .LDA(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xBD, // LDA indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction LDA indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .LDA(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xB9, // LDA indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction LDX absolute" {
    const instructions: []const Instruction = &.{
        .LDX(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xAE, // LDX absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction LDX indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .LDX(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xBE, // LDX indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction LDY absolute" {
    const instructions: []const Instruction = &.{
        .LDY(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xAC, // LDY absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction LDY indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .LDY(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xBC, // LDY indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction LSR absolute" {
    const instructions: []const Instruction = &.{
        .LSR(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x4E, // LSR absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction LSR indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .LSR(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x5E, // LSR indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ORA absolute" {
    const instructions: []const Instruction = &.{
        .ORA(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x0D, // ORA absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ORA indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .ORA(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x1D, // ORA indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ORA indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .ORA(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x19, // ORA indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ROL absolute" {
    const instructions: []const Instruction = &.{
        .ROL(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x2E, // ROL absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ROL indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .ROL(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x3E, // ROL indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ROR absolute" {
    const instructions: []const Instruction = &.{
        .ROR(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x6E, // ROR absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ROR indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .ROR(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x7E, // ROR indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction SBC absolute" {
    const instructions: []const Instruction = &.{
        .SBC(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xED, // SBC absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction SBC indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .SBC(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xFD, // SBC indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction SBC indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .SBC(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xF9, // SBC indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction STA absolute" {
    const instructions: []const Instruction = &.{
        .STA(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x8D, // STA absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction STA indexed_absolute_x" {
    const instructions: []const Instruction = &.{
        .STA(.indexed_absolute_x, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x9D, // STA indexed_absolute_x 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction STA indexed_absolute_y" {
    const instructions: []const Instruction = &.{
        .STA(.indexed_absolute_y, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x99, // STA indexed_absolute_y 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction STX absolute" {
    const instructions: []const Instruction = &.{
        .STX(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x8E, // STX absolute 0x00, 0xF0
        //
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction STY absolute" {
    const instructions: []const Instruction = &.{
        .STY(.absolute, .fromInt(0xF000)),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x8C,
        0x00,
        0xF0,
    }), bytes);
}

test "generate instruction ADC immediate" {
    const instructions: []const Instruction = &.{
        .ADC(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x69, // ADC immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction ADC indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .ADC(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x75, // ADC indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction ADC pre_indexed_indirect_zero_x" {
    const instructions: []const Instruction = &.{
        .ADC(.pre_indexed_indirect_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x61, // ADC pre_indexed_indirect_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction ADC post_indexed_indirect_zero_y" {
    const instructions: []const Instruction = &.{
        .ADC(.post_indexed_indirect_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x71, // ADC post_indexed_indirect_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction ADC zero" {
    const instructions: []const Instruction = &.{
        .ADC(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x65, // ADC zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction AND immediate" {
    const instructions: []const Instruction = &.{
        .AND(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x29, // AND immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction AND indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .AND(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x35, // AND indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction AND pre_indexed_indirect_zero_x" {
    const instructions: []const Instruction = &.{
        .AND(.pre_indexed_indirect_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x21, // AND pre_indexed_indirect_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction AND post_indexed_indirect_zero_y" {
    const instructions: []const Instruction = &.{
        .AND(.post_indexed_indirect_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x31, // AND post_indexed_indirect_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction AND zero" {
    const instructions: []const Instruction = &.{
        .AND(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x25, // AND zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction ASL indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .ASL(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x16, // ASL indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction ASL zero" {
    const instructions: []const Instruction = &.{
        .ASL(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x06, // ASL zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction BCC relative" {
    const instructions: []const Instruction = &.{
        .BCC(.relative, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x90, // BCC relative 0x0
        0xFE,
    }), bytes);
}

test "generate instruction BCS relative" {
    const instructions: []const Instruction = &.{
        .BCS(.relative, -0x2),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xB0, // BCS relative -0x2
        0xFC,
    }), bytes);
}

test "generate instruction BEQ relative" {
    const instructions: []const Instruction = &.{
        .BEQ(.relative, -0x4),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xF0, // BEQ relative -0x4
        0xFA,
    }), bytes);
}

test "generate instruction BIT zero" {
    const instructions: []const Instruction = &.{
        .BIT(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x24, // BIT zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction BMI relative" {
    const instructions: []const Instruction = &.{
        .BMI(.relative, -0x8),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x30, // BMI relative -0x8
        0xF6,
    }), bytes);
}

test "generate instruction BNE relative" {
    const instructions: []const Instruction = &.{
        .BNE(.relative, -0x6),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xD0, // BNE relative -0x6
        0xF8,
    }), bytes);
}

test "generate instruction BPL relative" {
    const instructions: []const Instruction = &.{
        .BPL(.relative, -0x10),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x10, // BPL relative -0x10
        0xEE,
    }), bytes);
}

test "generate instruction BVC relative" {
    const instructions: []const Instruction = &.{
        .BVC(.relative, -0x12),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x50, // BVC relative -0x12
        0xEC,
    }), bytes);
}

test "generate instruction BVS relative" {
    const instructions: []const Instruction = &.{
        .BVS(.relative, -0x14),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x70, // BVS relative -0x14
        0xEA,
    }), bytes);
}

test "generate instruction CMP immediate" {
    const instructions: []const Instruction = &.{
        .CMP(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xC9, // CMP immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction CMP indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .CMP(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xD5, // CMP indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction CMP pre_indexed_indirect_zero_x" {
    const instructions: []const Instruction = &.{
        .CMP(.pre_indexed_indirect_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xC1, // CMP pre_indexed_indirect_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction CMP post_indexed_indirect_zero_y" {
    const instructions: []const Instruction = &.{
        .CMP(.post_indexed_indirect_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xD1, // CMP post_indexed_indirect_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction CMP zero" {
    const instructions: []const Instruction = &.{
        .CMP(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xC5, // CMP zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction CPX immediate" {
    const instructions: []const Instruction = &.{
        .CPX(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xE0, // CPX immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction CPX zero" {
    const instructions: []const Instruction = &.{
        .CPX(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xE4, // CPX zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction CPY immediate" {
    const instructions: []const Instruction = &.{
        .CPY(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xC0, // CPY immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction CPY zero" {
    const instructions: []const Instruction = &.{
        .CPY(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xC4, // CPY zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction DEC indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .DEC(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xD6, // DEC indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction DEC zero" {
    const instructions: []const Instruction = &.{
        .DEC(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xC6, // DEC zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction EOR immediate" {
    const instructions: []const Instruction = &.{
        .EOR(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x49, // EOR immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction EOR indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .EOR(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x55, // EOR indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction EOR pre_indexed_indirect_zero_x" {
    const instructions: []const Instruction = &.{
        .EOR(.pre_indexed_indirect_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x41, // EOR pre_indexed_indirect_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction EOR post_indexed_indirect_zero_y" {
    const instructions: []const Instruction = &.{
        .EOR(.post_indexed_indirect_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x51, // EOR post_indexed_indirect_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction EOR zero" {
    const instructions: []const Instruction = &.{
        .EOR(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x45, // EOR zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction INC indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .INC(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xF6, // INC indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction INC zero" {
    const instructions: []const Instruction = &.{
        .INC(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xE6, // INC zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction LDA immediate" {
    const instructions: []const Instruction = &.{
        .LDA(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xA9, // LDA immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction LDA indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .LDA(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xB5, // LDA indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction LDA pre_indexed_indirect_zero_x" {
    const instructions: []const Instruction = &.{
        .LDA(.pre_indexed_indirect_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xA1, // LDA pre_indexed_indirect_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction LDA post_indexed_indirect_zero_y" {
    const instructions: []const Instruction = &.{
        .LDA(.post_indexed_indirect_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xB1, // LDA post_indexed_indirect_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction LDA zero" {
    const instructions: []const Instruction = &.{
        .LDA(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xA5, // LDA zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction LDX immediate" {
    const instructions: []const Instruction = &.{
        .LDX(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xA2, // LDX immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction LDX indexed_zero_y" {
    const instructions: []const Instruction = &.{
        .LDX(.indexed_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xB6, // LDX indexed_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction LDX zero" {
    const instructions: []const Instruction = &.{
        .LDX(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xA6, // LDX zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction LDY immediate" {
    const instructions: []const Instruction = &.{
        .LDY(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xA0, // LDY immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction LDY indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .LDY(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xB4, // LDY indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction LDY zero" {
    const instructions: []const Instruction = &.{
        .LDY(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xA4, // LDY zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction LSR indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .LSR(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x56, // LSR indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction LSR zero" {
    const instructions: []const Instruction = &.{
        .LSR(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x46, // LSR zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction ORA immediate" {
    const instructions: []const Instruction = &.{
        .ORA(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x09, // ORA immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction ORA indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .ORA(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x15, // ORA indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction ORA pre_indexed_indirect_zero_x" {
    const instructions: []const Instruction = &.{
        .ORA(.pre_indexed_indirect_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x01, // ORA pre_indexed_indirect_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction ORA post_indexed_indirect_zero_y" {
    const instructions: []const Instruction = &.{
        .ORA(.post_indexed_indirect_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x11, // ORA post_indexed_indirect_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction ORA zero" {
    const instructions: []const Instruction = &.{
        .ORA(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x05, // ORA zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction ROL indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .ROL(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x36, // ROL indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction ROL zero" {
    const instructions: []const Instruction = &.{
        .ROL(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x26, // ROL zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction ROR indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .ROR(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x76, // ROR indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction ROR zero" {
    const instructions: []const Instruction = &.{
        .ROR(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x66, // ROR zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction SBC immediate" {
    const instructions: []const Instruction = &.{
        .SBC(.immediate, 0x1),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xE9, // SBC immediate 0x01
        0x1,
    }), bytes);
}

test "generate instruction SBC indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .SBC(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xF5, // SBC indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction SBC pre_indexed_indirect_zero_x" {
    const instructions: []const Instruction = &.{
        .SBC(.pre_indexed_indirect_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xE1, // SBC pre_indexed_indirect_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction SBC post_indexed_indirect_zero_y" {
    const instructions: []const Instruction = &.{
        .SBC(.post_indexed_indirect_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xF1, // SBC post_indexed_indirect_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction SBC zero" {
    const instructions: []const Instruction = &.{
        .SBC(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0xE5, // SBC zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction STA indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .STA(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x95, // STA indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction STA pre_indexed_indirect_zero_x" {
    const instructions: []const Instruction = &.{
        .STA(.pre_indexed_indirect_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x81, // STA pre_indexed_indirect_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction STA post_indexed_indirect_zero_y" {
    const instructions: []const Instruction = &.{
        .STA(.post_indexed_indirect_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x91, // STA post_indexed_indirect_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction STA zero" {
    const instructions: []const Instruction = &.{
        .STA(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x85, // STA zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction STX indexed_zero_y" {
    const instructions: []const Instruction = &.{
        .STX(.indexed_zero_y, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x96, // STX indexed_zero_y 0x00
        0x0,
    }), bytes);
}

test "generate instruction STX zero" {
    const instructions: []const Instruction = &.{
        .STX(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x86, // STX zero 0x00
        0x0,
    }), bytes);
}

test "generate instruction STY indexed_zero_x" {
    const instructions: []const Instruction = &.{
        .STY(.indexed_zero_x, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x94, // STY indexed_zero_x 0x00
        0x0,
    }), bytes);
}

test "generate instruction STY zero" {
    const instructions: []const Instruction = &.{
        .STY(.zero, 0x0),
    };
    const bytes = try getInstructionsAsBytes(instructions);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualDeep(@as([]const u8, &.{
        0x84, // STY zero 0x00
        0x0,
    }), bytes);
}

const CPUTester = struct {
    fixture: MOS6502 = .{},
    expected: MOS6502,
    instruction: Instruction,
    program: []const u8,
    memory: []const u8,

    pub fn init(comptime instruction: Instruction, memory: []const u8) !@This() {
        const reseted = MOS6502.init();
        switch (instruction.mode) {
            inline else => |s, t| {
                // const initial_data_bus: Byte = switch (comptime instruction.mode) {
                //     .immediate => .fromInt(s.arg),
                //     else => if (comptime @TypeOf(s.arg) == void) .zero else if (comptime @TypeOf(s.arg) == Word) .fromInt(memory[s.arg.toInt()]) else if (comptime @TypeOf(s.arg) == i8) .zero else .fromInt(memory[s.arg]),
                // };
                const expected_addr: u16 = @bitSizeOf(@typeInfo(@TypeOf(s)).@"struct".backing_integer.?) / 8;
                return .{
                    .expected = .{
                        .read_write = .read,
                        .instr_cycle_count = 1,
                        .clock_cycles = instruction.type.available_modes.get(t).?.base_cycles + 1 + 2,
                        .instruction_register = .fromInt(s.opcode),
                        .address_bus = .fromInt(expected_addr),
                        .registers = .{
                            .s = reseted.registers.s,
                            .pc = .fromInt(expected_addr + 1),
                        },
                        .instr_addr = 0,
                        .inputs = .{ .prev_res = 1 },
                        .flags = .{ .irq_disable = 1 },
                    },
                    .instruction = instruction,
                    .program = try getInstructionsAsBytes(&.{ instruction, .NOP(.implicit, {}) }),
                    .memory = memory,
                };
            },
        }
    }

    pub fn deinit(self: *@This()) void {
        std.testing.allocator.free(self.program);
    }

    fn expectStartSequence(self: *CPUTester) !void {
        try self.expectRead(0, self.program);
        try self.expectRead(0xFFFC, null);
        self.fixture.data_bus = .fromInt(0x00);
        try self.expectRead(0xFFFD, null);
        self.fixture.data_bus = .fromInt(0x00);
    }

    fn expectRead(self: *@This(), addr: u16, source: ?[]const u8) !void {
        self.fixture.inputs.clock = 0;
        _ = try self.fixture.update();

        self.fixture.inputs.clock = 1;
        try std.testing.expectEqual(.read, self.fixture.read_write);
        try std.testing.expectEqual(addr, self.fixture.address_bus.toInt());
        const data = if (source) |s| s[self.fixture.address_bus.toInt()] else 0xaa;
        self.fixture.data_bus = .fromInt(data);
        _ = try self.fixture.update();
    }

    // fn expectWriteInternal(self: *@This(), target: MOS6502.CPUTarget) !Byte {
    //     self.fixture.inputs.clock = 0;
    //     try self.fixture.update();
    //
    //     self.fixture.inputs.clock = 1;
    //     try std.testing.expectEqual(.write, self.fixture.read_write);
    //     try std.testing.expectEqual(addr, self.fixture.address_bus.toInt());
    //     try self.fixture.update();
    //
    //     return self.fixture.data_bus;
    // }

    fn expectWrite(self: *@This(), addr: u16, expected_write: u8) !void {
        self.fixture.inputs.clock = 0;
        _ = try self.fixture.update();

        try std.testing.expectEqual(.write, self.fixture.read_write);
        try std.testing.expectEqual(addr, self.fixture.address_bus.toInt());
        try std.testing.expectEqual(expected_write, self.fixture.data_bus.toInt());

        self.fixture.inputs.clock = 1;
        _ = try self.fixture.update();
    }

    fn expectExecute(self: *@This()) !void {
        self.fixture.inputs.clock = 0;
        _ = try self.fixture.update();
    }

    pub fn testExpected(self: *@This()) !void {
        self.expected.registers.dl = self.fixture.registers.dl;
        try std.testing.expectEqualDeep(self.expected, self.fixture);
    }
};

fn testImmediateReadMode(tester: *CPUTester) !void {
    try tester.expectStartSequence();
    try tester.expectRead(0, tester.program);
    try tester.expectRead(1, tester.program);
    try tester.expectExecute();
}

fn testZeroReadMode(tester: *CPUTester) !void {
    try tester.expectStartSequence();
    try tester.expectRead(0, tester.program);
    try tester.expectRead(1, tester.program);
    try tester.expectRead(tester.instruction.mode.zero.arg, tester.memory);
    try tester.expectExecute();
}

fn testZeroWriteMode(tester: *CPUTester, expected_write: u8) !void {
    try tester.expectStartSequence();
    try tester.expectRead(0, tester.program);
    try tester.expectRead(1, tester.program);
    try tester.expectWrite(tester.instruction.mode.zero.arg, expected_write);
    try tester.expectExecute();
    tester.expected.data_bus = .fromInt(expected_write);
}

fn testAbsoluteWriteMode(tester: *CPUTester, expected_write: u8) !void {
    try tester.expectStartSequence();
    try tester.expectRead(0, tester.program);
    try tester.expectRead(1, tester.program);
    try tester.expectRead(2, tester.program);
    try tester.expectWrite(tester.instruction.mode.absolute.arg.toInt(), expected_write);
    try tester.expectExecute();
    tester.expected.data_bus = .fromInt(expected_write);
}

fn testImplicitInternalMode(tester: *CPUTester) !void {
    try tester.expectStartSequence();
    try tester.expectRead(0, tester.program);
    try tester.expectRead(1, tester.program);
    try tester.expectExecute();
    tester.expected.data_bus = .fromInt(0xEA);
    tester.expected.registers.pc = .fromInt(0x0002);
    tester.expected.address_bus = .fromInt(0x0001);
}

const TestRelativeMode = enum { no_branch, branch_no_page_fetch, branch_with_page_fetch };

fn testRelativeBranchMode(tester: *CPUTester, mode: TestRelativeMode) !void {
    try tester.expectStartSequence();
    try tester.expectRead(0, tester.program);
    try tester.expectRead(1, tester.program);
    const offset = tester.instruction.mode.relative.arg;

    switch (mode) {
        .no_branch => {
            tester.expected.data_bus = @bitCast(offset);
        },
        .branch_no_page_fetch, .branch_with_page_fetch => {
            var read_addr = Word.fromInt(2);
            if (offset < 0) {
                read_addr.lo = read_addr.lo.sub(.fromInt(@abs(offset)));
            } else {
                read_addr.lo = read_addr.lo.add(.fromInt(@abs(offset)));
            }
            try tester.expectRead(read_addr.toInt(), null);
            tester.expected.clock_cycles += 1;
            tester.expected.data_bus = .fromInt(0xaa);

            if (mode == .branch_with_page_fetch) {
                read_addr = .fromInt(@bitCast(2 +% @as(i16, offset)));
                try tester.expectRead(read_addr.toInt(), null);
                tester.expected.clock_cycles += 1;
            }

            tester.expected.address_bus = read_addr;
            tester.expected.registers.pc = read_addr;
            tester.expected.registers.pc.inc();
        },
    }
    try tester.expectExecute();
}

test "instruction operation LDA" {
    var immediate_case = try CPUTester.init(.LDA(.immediate, 0x42), &.{});
    defer immediate_case.deinit();
    try testImmediateReadMode(&immediate_case);
    immediate_case.expected.registers.a = .fromInt(0x42);
    immediate_case.expected.data_bus = .fromInt(0x42);
    try immediate_case.testExpected();

    var zero_case = try CPUTester.init(.LDA(.zero, 0x01), &.{ 0xef, 0xab, 0x0c });
    defer zero_case.deinit();
    try testZeroReadMode(&zero_case);
    zero_case.expected.registers.a = .fromInt(0xab);
    zero_case.expected.flags.negative = 1;
    zero_case.expected.data_bus = .fromInt(0xab);
    try zero_case.testExpected();
}

test "instruction operation ADC" {
    var basic_case = try CPUTester.init(.ADC(.immediate, 0x42), &.{});
    defer basic_case.deinit();
    basic_case.fixture.registers.a = .fromInt(0x3);
    try testImmediateReadMode(&basic_case);
    basic_case.expected.registers.a = .fromInt(0x45);
    basic_case.expected.data_bus = .fromInt(0x42);
    try basic_case.testExpected();

    var overflow_positive_case = try CPUTester.init(.ADC(.immediate, 0x70), &.{});
    defer overflow_positive_case.deinit();
    overflow_positive_case.fixture.registers.a = .fromInt(0x70);
    try testImmediateReadMode(&overflow_positive_case);
    overflow_positive_case.expected.registers.a = .fromInt(0xe0);
    overflow_positive_case.expected.data_bus = .fromInt(0x70);
    overflow_positive_case.expected.flags.overflow = 1;
    overflow_positive_case.expected.flags.negative = 1;
    try overflow_positive_case.testExpected();

    var overflow_negative_case = try CPUTester.init(.ADC(.immediate, 0x81), &.{});
    defer overflow_negative_case.deinit();
    overflow_negative_case.fixture.registers.a = .fromInt(0x81);
    try testImmediateReadMode(&overflow_negative_case);
    overflow_negative_case.expected.registers.a = .fromInt(0x02);
    overflow_negative_case.expected.data_bus = .fromInt(0x81);
    overflow_negative_case.expected.flags.overflow = 1;
    overflow_negative_case.expected.flags.carry = 1;
    try overflow_negative_case.testExpected();
}

test "instruction operation decimal mode ADC" {
    var basic_case = try CPUTester.init(.ADC(.immediate, 0x11), &.{});
    defer basic_case.deinit();
    basic_case.fixture.flags.decimal_mode = 1;
    basic_case.fixture.registers.a = .fromInt(0x22);
    try testImmediateReadMode(&basic_case);
    basic_case.expected.registers.a = .fromInt(0x33);
    basic_case.expected.data_bus = .fromInt(0x11);
    basic_case.expected.flags.decimal_mode = 1;
    try basic_case.testExpected();

    var lo_nibble_carry_case = try CPUTester.init(.ADC(.immediate, 0x17), &.{});
    defer lo_nibble_carry_case.deinit();
    lo_nibble_carry_case.fixture.flags.decimal_mode = 1;
    lo_nibble_carry_case.fixture.registers.a = .fromInt(0x04);
    try testImmediateReadMode(&lo_nibble_carry_case);
    lo_nibble_carry_case.expected.registers.a = .fromInt(0x21);
    lo_nibble_carry_case.expected.data_bus = .fromInt(0x17);
    lo_nibble_carry_case.expected.flags.decimal_mode = 1;
    try lo_nibble_carry_case.testExpected();

    var hi_nibble_carry_case = try CPUTester.init(.ADC(.immediate, 0x75), &.{});
    defer hi_nibble_carry_case.deinit();
    hi_nibble_carry_case.fixture.flags.decimal_mode = 1;
    hi_nibble_carry_case.fixture.registers.a = .fromInt(0x43);
    try testImmediateReadMode(&hi_nibble_carry_case);
    hi_nibble_carry_case.expected.registers.a = .fromInt(0x18);
    hi_nibble_carry_case.expected.data_bus = .fromInt(0x75);
    hi_nibble_carry_case.expected.flags.decimal_mode = 1;
    hi_nibble_carry_case.expected.flags.overflow = 1;
    hi_nibble_carry_case.expected.flags.carry = 1;
    try hi_nibble_carry_case.testExpected();

    var lo_hi_nibble_carry_case = try CPUTester.init(.ADC(.immediate, 0x78), &.{});
    defer lo_hi_nibble_carry_case.deinit();
    lo_hi_nibble_carry_case.fixture.flags.decimal_mode = 1;
    lo_hi_nibble_carry_case.fixture.registers.a = .fromInt(0x43);
    try testImmediateReadMode(&lo_hi_nibble_carry_case);
    lo_hi_nibble_carry_case.expected.registers.a = .fromInt(0x21);
    lo_hi_nibble_carry_case.expected.data_bus = .fromInt(0x78);
    lo_hi_nibble_carry_case.expected.flags.decimal_mode = 1;
    lo_hi_nibble_carry_case.expected.flags.overflow = 1;
    lo_hi_nibble_carry_case.expected.flags.carry = 1;
    try lo_hi_nibble_carry_case.testExpected();
}

test "instruction operation ADC zero" {
    var basic_case = try CPUTester.init(.ADC(.zero, 0x1), &.{ 0xaa, 0x03, 0xaa });
    defer basic_case.deinit();
    basic_case.fixture.registers.a = .fromInt(0x5);
    try testZeroReadMode(&basic_case);
    basic_case.expected.registers.a = .fromInt(0x8);
    basic_case.expected.data_bus = .fromInt(0x3);
    try basic_case.testExpected();
}

test "instruction operation ADC indexed zero x" {
    var basic_case = try CPUTester.init(.ADC(.indexed_zero_x, 0x1), &.{ 0xaa, 0x03, 0x05 });
    defer basic_case.deinit();
    basic_case.fixture.registers.a = .fromInt(0x5);
    basic_case.fixture.registers.x = .fromInt(0x1);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x1, basic_case.memory);
    try basic_case.expectRead(0x2, basic_case.memory);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0xa);
    basic_case.expected.registers.x = .fromInt(0x1);
    basic_case.expected.data_bus = .fromInt(0x5);
    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.ADC(.indexed_zero_x, 0xff), &.{});
    defer wrap_case.deinit();
    wrap_case.fixture.registers.a = .fromInt(0x5);
    wrap_case.fixture.registers.x = .fromInt(0x3);

    try wrap_case.expectStartSequence();
    try wrap_case.expectRead(0, wrap_case.program);
    try wrap_case.expectRead(1, wrap_case.program);
    try wrap_case.expectRead(0xff, null);
    try wrap_case.expectRead(0x02, null);
    wrap_case.fixture.data_bus = .fromInt(0x5);
    try wrap_case.expectExecute();

    wrap_case.expected.registers.a = .fromInt(0xa);
    wrap_case.expected.registers.x = .fromInt(0x3);
    wrap_case.expected.data_bus = .fromInt(0x5);
    try wrap_case.testExpected();
}

test "instruction operation ADC absolute" {
    var basic_case = try CPUTester.init(.ADC(.absolute, .fromInt(0xee)), &.{});
    defer basic_case.deinit();
    basic_case.fixture.registers.a = .fromInt(0x5);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xee, null);
    basic_case.fixture.data_bus = .fromInt(0x8);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0xd);
    basic_case.expected.data_bus = .fromInt(0x8);
    try basic_case.testExpected();
}

test "instruction operation ADC indexed absolute y" {
    var basic_case = try CPUTester.init(.ADC(.indexed_absolute_y, .fromInt(0xee)), &.{});
    defer basic_case.deinit();
    basic_case.fixture.registers.a = .fromInt(0x5);
    basic_case.fixture.registers.y = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xee + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0x8);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0xd);
    basic_case.expected.registers.y = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0x8);
    try basic_case.testExpected();
}

test "instruction operation ADC pre indexed indirect zero x" {
    var basic_case = try CPUTester.init(.ADC(.pre_indexed_indirect_zero_x, 0xee), &.{});
    defer basic_case.deinit();
    basic_case.fixture.registers.a = .fromInt(0x5);
    basic_case.fixture.registers.x = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0xee, null);
    try basic_case.expectRead(0xee + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0xf0);
    try basic_case.expectRead(0xee + 0x4, null);
    basic_case.fixture.data_bus = .fromInt(0xe0);
    try basic_case.expectRead(0xe0f0, null);
    basic_case.fixture.data_bus = .fromInt(0x8);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0xd);
    basic_case.expected.registers.x = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0x8);
    try basic_case.testExpected();
}

test "instruction operation ADC post indexed indirect zero y" {
    var basic_case = try CPUTester.init(.ADC(.post_indexed_indirect_zero_y, 0xee), &.{});
    defer basic_case.deinit();
    basic_case.fixture.registers.a = .fromInt(0x5);
    basic_case.fixture.registers.y = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0xee, null);
    basic_case.fixture.data_bus = .fromInt(0xf0);
    try basic_case.expectRead(0xee + 0x1, null);
    basic_case.fixture.data_bus = .fromInt(0xe0);
    try basic_case.expectRead(0xe0f0 + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0x8);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0xd);
    basic_case.expected.registers.y = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0x8);
    try basic_case.testExpected();

    var page_increase_case = try CPUTester.init(.ADC(.post_indexed_indirect_zero_y, 0xee), &.{});
    defer page_increase_case.deinit();
    page_increase_case.fixture.registers.a = .fromInt(0x5);
    page_increase_case.fixture.registers.y = .fromInt(0x3);

    try page_increase_case.expectStartSequence();
    try page_increase_case.expectRead(0, page_increase_case.program);
    try page_increase_case.expectRead(1, page_increase_case.program);
    try page_increase_case.expectRead(0xee, null);
    page_increase_case.fixture.data_bus = .fromInt(0xff);
    try page_increase_case.expectRead(0xee + 0x1, null);
    page_increase_case.fixture.data_bus = .fromInt(0xe0);
    try page_increase_case.expectRead(0xe102, null);
    try page_increase_case.expectRead(0xe102, null);
    page_increase_case.fixture.data_bus = .fromInt(0x8);
    try page_increase_case.expectExecute();

    page_increase_case.expected.registers.a = .fromInt(0xd);
    page_increase_case.expected.registers.y = .fromInt(0x3);
    page_increase_case.expected.data_bus = .fromInt(0x8);
    page_increase_case.expected.clock_cycles += 1;
    try page_increase_case.testExpected();
}

test "instruction operation SBC" {
    var basic_case = try CPUTester.init(.SBC(.immediate, 0x3), &.{});
    defer basic_case.deinit();
    basic_case.fixture.registers.a = .fromInt(0x42);
    basic_case.fixture.flags.carry = 1;
    try testImmediateReadMode(&basic_case);
    basic_case.expected.registers.a = .fromInt(0x3f);
    basic_case.expected.data_bus = .fromInt(0x3);
    basic_case.expected.flags.carry = 1;
    try basic_case.testExpected();

    var zero_case = try CPUTester.init(.SBC(.immediate, 0x70), &.{});
    defer zero_case.deinit();
    zero_case.fixture.registers.a = .fromInt(0x70);
    zero_case.fixture.flags.carry = 1;
    try testImmediateReadMode(&zero_case);
    zero_case.expected.registers.a = .fromInt(0x00);
    zero_case.expected.data_bus = .fromInt(0x70);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.carry = 1;
    try zero_case.testExpected();

    var overflow_case = try CPUTester.init(.SBC(.immediate, 0x85), &.{});
    defer overflow_case.deinit();
    overflow_case.fixture.registers.a = .fromInt(0x10);
    overflow_case.fixture.flags.carry = 1;
    try testImmediateReadMode(&overflow_case);
    overflow_case.expected.registers.a = .fromInt(0x8b);
    overflow_case.expected.data_bus = .fromInt(0x85);
    overflow_case.expected.flags.negative = 1;
    overflow_case.expected.flags.overflow = 1;
    try overflow_case.testExpected();
}

test "instruction operation decimal mode SBC" {
    var basic_case = try CPUTester.init(.SBC(.immediate, 0x11), &.{});
    defer basic_case.deinit();
    basic_case.fixture.flags.decimal_mode = 1;
    basic_case.fixture.flags.carry = 1;
    basic_case.fixture.registers.a = .fromInt(0x22);
    try testImmediateReadMode(&basic_case);
    basic_case.expected.registers.a = .fromInt(0x11);
    basic_case.expected.data_bus = .fromInt(0x11);
    basic_case.expected.flags.decimal_mode = 1;
    basic_case.expected.flags.carry = 1;
    try basic_case.testExpected();

    var lo_nibble_carry_case = try CPUTester.init(.SBC(.immediate, 0x04), &.{});
    defer lo_nibble_carry_case.deinit();
    lo_nibble_carry_case.fixture.flags.decimal_mode = 1;
    lo_nibble_carry_case.fixture.flags.carry = 1;
    lo_nibble_carry_case.fixture.registers.a = .fromInt(0x17);
    try testImmediateReadMode(&lo_nibble_carry_case);
    lo_nibble_carry_case.expected.registers.a = .fromInt(0x13);
    lo_nibble_carry_case.expected.data_bus = .fromInt(0x04);
    lo_nibble_carry_case.expected.flags.decimal_mode = 1;
    lo_nibble_carry_case.expected.flags.carry = 1;
    try lo_nibble_carry_case.testExpected();

    var hi_nibble_carry_case = try CPUTester.init(.SBC(.immediate, 0x43), &.{});
    defer hi_nibble_carry_case.deinit();
    hi_nibble_carry_case.fixture.flags.decimal_mode = 1;
    hi_nibble_carry_case.fixture.flags.carry = 1;
    hi_nibble_carry_case.fixture.registers.a = .fromInt(0x75);
    try testImmediateReadMode(&hi_nibble_carry_case);
    hi_nibble_carry_case.expected.registers.a = .fromInt(0x32);
    hi_nibble_carry_case.expected.data_bus = .fromInt(0x43);
    hi_nibble_carry_case.expected.flags.decimal_mode = 1;
    hi_nibble_carry_case.expected.flags.carry = 1;
    try hi_nibble_carry_case.testExpected();

    var lo_hi_nibble_carry_case = try CPUTester.init(.SBC(.immediate, 0x49), &.{});
    defer lo_hi_nibble_carry_case.deinit();
    lo_hi_nibble_carry_case.fixture.flags.decimal_mode = 1;
    lo_hi_nibble_carry_case.fixture.flags.carry = 1;
    lo_hi_nibble_carry_case.fixture.registers.a = .fromInt(0x78);
    try testImmediateReadMode(&lo_hi_nibble_carry_case);
    lo_hi_nibble_carry_case.expected.registers.a = .fromInt(0x29);
    lo_hi_nibble_carry_case.expected.data_bus = .fromInt(0x49);
    lo_hi_nibble_carry_case.expected.flags.decimal_mode = 1;
    lo_hi_nibble_carry_case.expected.flags.carry = 1;
    try lo_hi_nibble_carry_case.testExpected();

    var negative_result_case = try CPUTester.init(.SBC(.immediate, 0x25), &.{});
    defer negative_result_case.deinit();
    negative_result_case.fixture.flags.decimal_mode = 1;
    negative_result_case.fixture.flags.carry = 1;
    negative_result_case.fixture.registers.a = .fromInt(0x10);
    try testImmediateReadMode(&negative_result_case);
    negative_result_case.expected.registers.a = .fromInt(0x85);
    negative_result_case.expected.data_bus = .fromInt(0x25);
    negative_result_case.expected.flags.decimal_mode = 1;
    negative_result_case.expected.flags.negative = 1;
    try negative_result_case.testExpected();

    var overflow_case = try CPUTester.init(.SBC(.immediate, 0x10), &.{});
    defer overflow_case.deinit();
    overflow_case.fixture.flags.decimal_mode = 1;
    overflow_case.fixture.flags.carry = 1;
    overflow_case.fixture.registers.a = .fromInt(0x85);
    try testImmediateReadMode(&overflow_case);
    overflow_case.expected.registers.a = .fromInt(0x75);
    overflow_case.expected.data_bus = .fromInt(0x10);
    overflow_case.expected.flags.decimal_mode = 1;
    overflow_case.expected.flags.overflow = 1;
    overflow_case.expected.flags.carry = 1;
    try overflow_case.testExpected();

    var ninety_nine_case = try CPUTester.init(.SBC(.immediate, 0x99), &.{});
    defer ninety_nine_case.deinit();
    ninety_nine_case.fixture.flags.decimal_mode = 1;
    ninety_nine_case.fixture.flags.carry = 0;
    ninety_nine_case.fixture.registers.a = .fromInt(0x99);
    try testImmediateReadMode(&ninety_nine_case);
    ninety_nine_case.expected.registers.a = .fromInt(0x99);
    ninety_nine_case.expected.data_bus = .fromInt(0x99);
    ninety_nine_case.expected.flags.decimal_mode = 1;
    ninety_nine_case.expected.flags.negative = 1;
    try ninety_nine_case.testExpected();
}

test "instruction operation STA zero" {
    var basic_case = try CPUTester.init(.STA(.zero, 0xab), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x33);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectWrite(0x00ab, 0x33);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x33);
    basic_case.expected.registers.a = .fromInt(0x33);

    try basic_case.testExpected();
}

test "instruction operation STA indexed zero x" {
    var basic_case = try CPUTester.init(.STA(.indexed_zero_x, 0xab), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x33);
    basic_case.fixture.registers.x = .fromInt(0x10);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x00ab, null);
    try basic_case.expectWrite(0x00bb, 0x33);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x33);
    basic_case.expected.registers.a = .fromInt(0x33);
    basic_case.expected.registers.x = .fromInt(0x10);

    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.STA(.indexed_zero_x, 0xff), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.registers.a = .fromInt(0x33);
    wrap_case.fixture.registers.x = .fromInt(0x10);

    try wrap_case.expectStartSequence();
    try wrap_case.expectRead(0, wrap_case.program);
    try wrap_case.expectRead(1, wrap_case.program);
    try wrap_case.expectRead(0x00ff, null);
    try wrap_case.expectWrite(0x000f, 0x33);
    try wrap_case.expectExecute();

    wrap_case.expected.data_bus = .fromInt(0x33);
    wrap_case.expected.registers.a = .fromInt(0x33);
    wrap_case.expected.registers.x = .fromInt(0x10);

    try wrap_case.testExpected();
}

test "instruction operation STA absolute" {
    var wrap_case = try CPUTester.init(.STA(.absolute, .fromInt(0xabff)), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.registers.a = .fromInt(0x33);

    try wrap_case.expectStartSequence();
    try wrap_case.expectRead(0, wrap_case.program);
    try wrap_case.expectRead(1, wrap_case.program);
    try wrap_case.expectRead(2, wrap_case.program);
    try wrap_case.expectWrite(0xabff, 0x33);
    try wrap_case.expectExecute();

    wrap_case.expected.data_bus = .fromInt(0x33);
    wrap_case.expected.registers.a = .fromInt(0x33);

    try wrap_case.testExpected();
}

test "instruction operation STA indexed absolute x" {
    var basic_case = try CPUTester.init(.STA(.indexed_absolute_x, .fromInt(0xabf0)), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x33);
    basic_case.fixture.registers.x = .fromInt(0x05);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xabf5, null);
    try basic_case.expectWrite(0xabf5, 0x33);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x33);
    basic_case.expected.registers.a = .fromInt(0x33);
    basic_case.expected.registers.x = .fromInt(0x05);

    try basic_case.testExpected();

    var next_page_case = try CPUTester.init(.STA(.indexed_absolute_x, .fromInt(0xabf0)), &.{});
    defer next_page_case.deinit();

    next_page_case.fixture.registers.a = .fromInt(0x33);
    next_page_case.fixture.registers.x = .fromInt(0x15);

    try next_page_case.expectStartSequence();
    try next_page_case.expectRead(0, next_page_case.program);
    try next_page_case.expectRead(1, next_page_case.program);
    try next_page_case.expectRead(2, next_page_case.program);
    try next_page_case.expectRead(0xac05, null);
    try next_page_case.expectWrite(0xac05, 0x33);
    try next_page_case.expectExecute();

    next_page_case.expected.data_bus = .fromInt(0x33);
    next_page_case.expected.registers.a = .fromInt(0x33);
    next_page_case.expected.registers.x = .fromInt(0x15);

    try next_page_case.testExpected();
}

test "instruction operation STA indexed absolute y" {
    var basic_case = try CPUTester.init(.STA(.indexed_absolute_y, .fromInt(0xabf0)), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x33);
    basic_case.fixture.registers.y = .fromInt(0x05);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xabf5, null);
    try basic_case.expectWrite(0xabf5, 0x33);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x33);
    basic_case.expected.registers.a = .fromInt(0x33);
    basic_case.expected.registers.y = .fromInt(0x05);

    try basic_case.testExpected();

    var next_page_case = try CPUTester.init(.STA(.indexed_absolute_y, .fromInt(0xabf0)), &.{});
    defer next_page_case.deinit();

    next_page_case.fixture.registers.a = .fromInt(0x33);
    next_page_case.fixture.registers.y = .fromInt(0x15);

    try next_page_case.expectStartSequence();
    try next_page_case.expectRead(0, next_page_case.program);
    try next_page_case.expectRead(1, next_page_case.program);
    try next_page_case.expectRead(2, next_page_case.program);
    try next_page_case.expectRead(0xac05, null);
    try next_page_case.expectWrite(0xac05, 0x33);
    try next_page_case.expectExecute();

    next_page_case.expected.data_bus = .fromInt(0x33);
    next_page_case.expected.registers.a = .fromInt(0x33);
    next_page_case.expected.registers.y = .fromInt(0x15);

    try next_page_case.testExpected();
}

test "instruction operation STA pre indexed indirect zero x" {
    var basic_case = try CPUTester.init(.STA(.pre_indexed_indirect_zero_x, 0xf0), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x33);
    basic_case.fixture.registers.x = .fromInt(0x05);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x00f0, null);
    try basic_case.expectRead(0x00f5, null);
    basic_case.fixture.data_bus = .fromInt(0x55);
    try basic_case.expectRead(0x00f6, null);
    basic_case.fixture.data_bus = .fromInt(0x44);
    try basic_case.expectWrite(0x4455, 0x33);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x33);
    basic_case.expected.registers.a = .fromInt(0x33);
    basic_case.expected.registers.x = .fromInt(0x05);

    try basic_case.testExpected();
}

test "instruction operation STA post indexed indirect zero y" {
    var basic_case = try CPUTester.init(.STA(.post_indexed_indirect_zero_y, 0xf0), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x33);
    basic_case.fixture.registers.y = .fromInt(0x05);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x00f0, null);
    basic_case.fixture.data_bus = .fromInt(0x55);
    try basic_case.expectRead(0x00f1, null);
    basic_case.fixture.data_bus = .fromInt(0x44);
    try basic_case.expectRead(0x445a, null);
    try basic_case.expectWrite(0x445a, 0x33);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x33);
    basic_case.expected.registers.a = .fromInt(0x33);
    basic_case.expected.registers.y = .fromInt(0x05);

    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.STA(.post_indexed_indirect_zero_y, 0xf0), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.registers.a = .fromInt(0x33);
    wrap_case.fixture.registers.y = .fromInt(0xb5);

    try wrap_case.expectStartSequence();
    try wrap_case.expectRead(0, wrap_case.program);
    try wrap_case.expectRead(1, wrap_case.program);
    try wrap_case.expectRead(0x00f0, null);
    wrap_case.fixture.data_bus = .fromInt(0x55);
    try wrap_case.expectRead(0x00f1, null);
    wrap_case.fixture.data_bus = .fromInt(0x44);
    try wrap_case.expectRead(0x440a, null);
    try wrap_case.expectWrite(0x440a, 0x33);
    try wrap_case.expectExecute();

    wrap_case.expected.data_bus = .fromInt(0x33);
    wrap_case.expected.registers.a = .fromInt(0x33);
    wrap_case.expected.registers.y = .fromInt(0xb5);

    try wrap_case.testExpected();
}

test "instruction operation STX absolute" {
    var basic_case = try CPUTester.init(.STX(.absolute, .fromInt(0x0001)), &.{ 0xef, 0xab, 0x0c });
    defer basic_case.deinit();

    basic_case.fixture.registers.x = .fromInt(0x33);
    basic_case.expected.registers.x = .fromInt(0x33);

    try testAbsoluteWriteMode(&basic_case, 0x33);
    try basic_case.testExpected();
}

test "instruction operation STX indexed_zero_y" {
    var basic_case = try CPUTester.init(.STX(.indexed_zero_y, 0x7c), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.x = .fromInt(0x33);
    basic_case.fixture.registers.y = .fromInt(0x1f);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x007c, null);
    try basic_case.expectWrite(0x007c + 0x1f, 0x33);
    try basic_case.expectExecute();

    basic_case.expected.registers.x = .fromInt(0x33);
    basic_case.expected.registers.y = .fromInt(0x1f);
    basic_case.expected.data_bus = .fromInt(0x33);

    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.STX(.indexed_zero_y, 0xff), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.registers.x = .fromInt(0x33);
    wrap_case.fixture.registers.y = .fromInt(0x1f);

    try wrap_case.expectStartSequence();
    try wrap_case.expectRead(0, wrap_case.program);
    try wrap_case.expectRead(1, wrap_case.program);
    try wrap_case.expectRead(0x00ff, null);
    try wrap_case.expectWrite(0x001e, 0x33);
    try wrap_case.expectExecute();

    wrap_case.expected.registers.x = .fromInt(0x33);
    wrap_case.expected.registers.y = .fromInt(0x1f);
    wrap_case.expected.data_bus = .fromInt(0x33);

    try wrap_case.testExpected();
}

test "instruction operation STY" {
    var absolute_case = try CPUTester.init(.STY(.absolute, .fromInt(0x0001)), &.{ 0xef, 0xab, 0x0c });
    defer absolute_case.deinit();

    absolute_case.fixture.registers.y = .fromInt(0x33);
    absolute_case.expected.registers.y = .fromInt(0x33);

    try testAbsoluteWriteMode(&absolute_case, 0x33);
    try absolute_case.testExpected();
}

test "instruction operation TXS" {
    var basic_case = try CPUTester.init(.TXS(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.registers.x = .fromInt(0x33);
    basic_case.expected.registers.x = .fromInt(0x33);
    basic_case.expected.registers.s = .fromInt(0x33);
    basic_case.expected.flags.negative = 1;
    basic_case.expected.flags.zero_ = 1;

    try testImplicitInternalMode(&basic_case);
    try basic_case.testExpected();
}

test "instruction operation INX" {
    var basic_case = try CPUTester.init(.INX(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.registers.x = .fromInt(0x33);
    basic_case.expected.registers.x = .fromInt(0x34);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;

    try testImplicitInternalMode(&basic_case);
    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.INX(.implicit, {}), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.flags.zero_ = 0;
    wrap_case.fixture.flags.negative = 1;
    wrap_case.fixture.registers.x = .fromInt(0xff);
    wrap_case.expected.registers.x = .fromInt(0x00);
    wrap_case.expected.flags.zero_ = 1;
    wrap_case.expected.flags.negative = 0;

    try testImplicitInternalMode(&wrap_case);
    try wrap_case.testExpected();

    var negative_case = try CPUTester.init(.INX(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.negative = 0;
    negative_case.fixture.registers.x = .fromInt(0xfe);
    negative_case.expected.registers.x = .fromInt(0xff);
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.negative = 1;

    try testImplicitInternalMode(&negative_case);
    try negative_case.testExpected();
}

test "instruction operation INY" {
    var basic_case = try CPUTester.init(.INY(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.registers.y = .fromInt(0x33);
    basic_case.expected.registers.y = .fromInt(0x34);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;

    try testImplicitInternalMode(&basic_case);
    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.INY(.implicit, {}), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.flags.zero_ = 0;
    wrap_case.fixture.flags.negative = 1;
    wrap_case.fixture.registers.y = .fromInt(0xff);
    wrap_case.expected.registers.y = .fromInt(0x00);
    wrap_case.expected.flags.zero_ = 1;
    wrap_case.expected.flags.negative = 0;

    try testImplicitInternalMode(&wrap_case);
    try wrap_case.testExpected();

    var negative_case = try CPUTester.init(.INY(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.negative = 0;
    negative_case.fixture.registers.y = .fromInt(0xfe);
    negative_case.expected.registers.y = .fromInt(0xff);
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.negative = 1;

    try testImplicitInternalMode(&negative_case);
    try negative_case.testExpected();
}

test "instruction operation INC zero" {
    var basic_case = try CPUTester.init(.INC(.zero, 0x86), &.{});
    defer basic_case.deinit();

    try basic_case.expectStartSequence();

    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x86, null);
    basic_case.fixture.data_bus = .fromInt(0x03);
    try basic_case.expectWrite(0x86, 0x03);
    try basic_case.expectWrite(0x86, 0x04);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x04);

    try basic_case.testExpected();
}

test "instruction operation INC indexed zero x" {
    var basic_case = try CPUTester.init(.INC(.indexed_zero_x, 0xae), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.x = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0xae, null);
    try basic_case.expectRead(0xae + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0x62);
    try basic_case.expectWrite(0xae + 0x3, 0x62);
    try basic_case.expectWrite(0xae + 0x3, 0x63);
    try basic_case.expectExecute();

    basic_case.expected.registers.x = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0x63);

    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.INC(.indexed_zero_x, 0xff), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.registers.x = .fromInt(0x3);

    try wrap_case.expectStartSequence();
    try wrap_case.expectRead(0, wrap_case.program);
    try wrap_case.expectRead(1, wrap_case.program);
    try wrap_case.expectRead(0xff, null);
    try wrap_case.expectRead(0x02, null);
    wrap_case.fixture.data_bus = .fromInt(0x62);
    try wrap_case.expectWrite(0x02, 0x62);
    try wrap_case.expectWrite(0x02, 0x63);
    try wrap_case.expectExecute();

    wrap_case.expected.registers.x = .fromInt(0x3);
    wrap_case.expected.data_bus = .fromInt(0x63);

    try wrap_case.testExpected();
}

test "instruction operation INC absolute" {
    var basic_case = try CPUTester.init(.INC(.absolute, .fromInt(0xabcd)), &.{});
    defer basic_case.deinit();

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xabcd, null);
    basic_case.fixture.data_bus = .fromInt(0x56);
    try basic_case.expectWrite(0xabcd, 0x56);
    try basic_case.expectWrite(0xabcd, 0x57);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x57);

    try basic_case.testExpected();
}

test "instruction operation INC indexed absolute x" {
    var basic_case = try CPUTester.init(.INC(.indexed_absolute_x, .fromInt(0xee55)), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.x = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xee55 + 0x3, null);
    try basic_case.expectRead(0xee55 + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0x2b);
    try basic_case.expectWrite(0xee55 + 0x3, 0x2b);
    try basic_case.expectWrite(0xee55 + 0x3, 0x2c);
    try basic_case.expectExecute();

    basic_case.expected.registers.x = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0x2c);

    try basic_case.testExpected();

    var page_fetch_case = try CPUTester.init(.INC(.indexed_absolute_x, .fromInt(0xeef5)), &.{});
    defer page_fetch_case.deinit();

    page_fetch_case.fixture.registers.x = .fromInt(0x10);

    try page_fetch_case.expectStartSequence();
    try page_fetch_case.expectRead(0, page_fetch_case.program);
    try page_fetch_case.expectRead(1, page_fetch_case.program);
    try page_fetch_case.expectRead(2, page_fetch_case.program);
    try page_fetch_case.expectRead(0xef05, null);
    try page_fetch_case.expectRead(0xef05, null);
    page_fetch_case.fixture.data_bus = .fromInt(0x2b);
    try page_fetch_case.expectWrite(0xef05, 0x2b);
    try page_fetch_case.expectWrite(0xef05, 0x2c);
    try page_fetch_case.expectExecute();

    page_fetch_case.expected.registers.x = .fromInt(0x10);
    page_fetch_case.expected.data_bus = .fromInt(0x2c);

    try page_fetch_case.testExpected();
}

fn testBranchInstruction(
    comptime instr: Instruction,
    comptime flag: std.meta.FieldEnum(MOS6502.Flags),
    comptime flag_state_when_branch: u1,
) !void {
    comptime var instr_ = instr;

    instr_.mode.relative.arg = 3;
    var no_branch_case = try CPUTester.init(instr_, &.{});
    defer no_branch_case.deinit();

    @field(no_branch_case.fixture.flags, @tagName(flag)) = ~flag_state_when_branch;
    @field(no_branch_case.expected.flags, @tagName(flag)) = ~flag_state_when_branch;

    try testRelativeBranchMode(&no_branch_case, .no_branch);
    try no_branch_case.testExpected();

    instr_.mode.relative.arg = 3;
    var branch_no_page_fetch_case = try CPUTester.init(instr_, &.{});
    defer branch_no_page_fetch_case.deinit();

    @field(branch_no_page_fetch_case.fixture.flags, @tagName(flag)) = flag_state_when_branch;
    @field(branch_no_page_fetch_case.expected.flags, @tagName(flag)) = flag_state_when_branch;

    try testRelativeBranchMode(&branch_no_page_fetch_case, .branch_no_page_fetch);
    try branch_no_page_fetch_case.testExpected();

    instr_.mode.relative.arg = -3;
    var branch_with_page_fetch_case = try CPUTester.init(instr_, &.{});
    defer branch_with_page_fetch_case.deinit();

    @field(branch_with_page_fetch_case.fixture.flags, @tagName(flag)) = flag_state_when_branch;
    @field(branch_with_page_fetch_case.expected.flags, @tagName(flag)) = flag_state_when_branch;

    try testRelativeBranchMode(&branch_with_page_fetch_case, .branch_with_page_fetch);
    try branch_with_page_fetch_case.testExpected();
}

test "instruction operation BNE" {
    try testBranchInstruction(.BNE(.relative, 0), .zero_, 0);
}

test "instruction operation BEQ" {
    try testBranchInstruction(.BEQ(.relative, 0), .zero_, 1);
}

test "instruction operation BCC" {
    try testBranchInstruction(.BCC(.relative, 0), .carry, 0);
}

test "instruction operation BCS" {
    try testBranchInstruction(.BCS(.relative, 0), .carry, 1);
}

test "instruction operation BVC" {
    try testBranchInstruction(.BVC(.relative, 0), .overflow, 0);
}

test "instruction operation BVS" {
    try testBranchInstruction(.BVS(.relative, 0), .overflow, 1);
}

test "instruction operation BPL" {
    try testBranchInstruction(.BPL(.relative, 0), .negative, 0);
}

test "instruction operation BMI" {
    try testBranchInstruction(.BMI(.relative, 0), .negative, 1);
}

test "instruction operation JSR" {
    var jsr_case = try CPUTester.init(.JSR(.absolute, .fromInt(0x1234)), &.{});
    defer jsr_case.deinit();

    try jsr_case.expectStartSequence();

    try jsr_case.expectRead(0, jsr_case.program);
    try jsr_case.expectRead(1, jsr_case.program);
    try jsr_case.expectRead(0x1FF, null);
    try jsr_case.expectWrite(0x01FF, 0x00);
    try jsr_case.expectWrite(0x01FE, 0x02);
    try jsr_case.expectRead(2, jsr_case.program);
    try jsr_case.expectExecute();
    jsr_case.expected.data_bus = .fromInt(0x12);
    jsr_case.expected.registers.pc = .fromInt(0x1235);
    jsr_case.expected.address_bus = .fromInt(0x1234);
    jsr_case.expected.registers.s = .fromInt(0xFD);
    try jsr_case.testExpected();
}

test "instruction operation RTS" {
    var rts_case = try CPUTester.init(.RTS(.implicit, {}), &.{});
    defer rts_case.deinit();

    try rts_case.expectStartSequence();

    rts_case.fixture.registers.s = .fromInt(0xFD);

    try rts_case.expectRead(0, rts_case.program);
    try rts_case.expectRead(1, null);
    try rts_case.expectRead(0x01FD, null);
    try rts_case.expectRead(0x01FE, null);
    try rts_case.expectRead(0x01FF, null);
    try rts_case.expectRead(0xaaaa, null);
    try rts_case.expectExecute();
    rts_case.expected.data_bus = .fromInt(0xaa);
    rts_case.expected.registers.pc = .fromInt(0xaaac);
    rts_case.expected.address_bus = .fromInt(0xaaab);
    rts_case.expected.registers.s = .fromInt(0xFF);
    try rts_case.testExpected();
}

test "instruction operation JMP" {
    var jmp_case = try CPUTester.init(.JMP(.absolute, .fromInt(0x1234)), &.{});
    defer jmp_case.deinit();

    try jmp_case.expectStartSequence();

    try jmp_case.expectRead(0, jmp_case.program);
    try jmp_case.expectRead(1, jmp_case.program);
    try jmp_case.expectRead(2, jmp_case.program);
    try jmp_case.expectExecute();
    jmp_case.expected.data_bus = .fromInt(0x12);
    jmp_case.expected.registers.pc = .fromInt(0x1235);
    jmp_case.expected.address_bus = .fromInt(0x1234);
    try jmp_case.testExpected();

    var jmp_far_case = try CPUTester.init(.JMP(.absolute, .fromInt(0xf234)), &.{});
    defer jmp_far_case.deinit();

    try jmp_far_case.expectStartSequence();

    try jmp_far_case.expectRead(0, jmp_far_case.program);
    try jmp_far_case.expectRead(1, jmp_far_case.program);
    try jmp_far_case.expectRead(2, jmp_far_case.program);
    try jmp_far_case.expectExecute();
    jmp_far_case.expected.data_bus = .fromInt(0xf2);
    jmp_far_case.expected.registers.pc = .fromInt(0xf235);
    jmp_far_case.expected.address_bus = .fromInt(0xf234);
    try jmp_far_case.testExpected();
}

test "instruction operation ASL implicit" {
    var basic_case = try CPUTester.init(.ASL(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b00100100);
    basic_case.fixture.flags.carry = 1;
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.zero_ = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b01001000);
    basic_case.expected.flags.carry = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.ASL(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0b01000000);
    negative_case.fixture.flags.carry = 1;
    negative_case.fixture.flags.negative = 0;
    negative_case.fixture.flags.zero_ = 1;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0b10000000);
    negative_case.expected.flags.carry = 0;
    negative_case.expected.flags.negative = 1;
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.data_bus = .fromInt(0xea);

    try negative_case.testExpected();

    var zero_and_carry_case = try CPUTester.init(.ASL(.implicit, {}), &.{});
    defer zero_and_carry_case.deinit();

    zero_and_carry_case.fixture.registers.a = .fromInt(0b10000000);
    zero_and_carry_case.fixture.flags.carry = 0;
    zero_and_carry_case.fixture.flags.negative = 1;
    zero_and_carry_case.fixture.flags.zero_ = 0;

    try zero_and_carry_case.expectStartSequence();
    try zero_and_carry_case.expectRead(0, zero_and_carry_case.program);
    try zero_and_carry_case.expectRead(1, zero_and_carry_case.program);
    try zero_and_carry_case.expectExecute();

    zero_and_carry_case.expected.registers.a = .fromInt(0b00000000);
    zero_and_carry_case.expected.flags.carry = 1;
    zero_and_carry_case.expected.flags.negative = 0;
    zero_and_carry_case.expected.flags.zero_ = 1;
    zero_and_carry_case.expected.data_bus = .fromInt(0xea);

    try zero_and_carry_case.testExpected();
}

test "instruction operation BRK immediate" {
    var basic_case = try CPUTester.init(.BRK(.immediate, 0x42), &.{});
    defer basic_case.deinit();

    try basic_case.expectStartSequence();
    basic_case.fixture.registers.s = .fromInt(0xff);
    basic_case.fixture.flags = @bitCast(@as(u8, 0b11001010));
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectWrite(0x01ff, 0x00);
    try basic_case.expectWrite(0x01fe, 0x02);
    try basic_case.expectWrite(0x01fd, 0b11111010);
    try basic_case.expectRead(0xfffe, null);
    basic_case.fixture.data_bus = .fromInt(0xce);
    try basic_case.expectRead(0xffff, null);
    basic_case.fixture.data_bus = .fromInt(0xf0);
    try basic_case.expectExecute();

    basic_case.expected.address_bus = .fromInt(0xf0ce);
    basic_case.expected.registers.pc = .fromInt(0xf0cf);
    basic_case.expected.registers.s = .fromInt(0xfc);
    basic_case.expected.flags = @bitCast(@as(u8, 0b11001010));
    basic_case.expected.data_bus = .fromInt(0xf0);

    try basic_case.testExpected();
}

test "instruction operation CLC implicit" {
    var basic_case = try CPUTester.init(.CLC(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.carry = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.flags.carry = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();
}

test "instruction operation CLD implicit" {
    var basic_case = try CPUTester.init(.CLD(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.decimal_mode = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.flags.decimal_mode = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();
}

test "instruction operation CLI implicit" {
    var basic_case = try CPUTester.init(.CLI(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.irq_disable = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.flags.irq_disable = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();
}

test "instruction operation CLV implicit" {
    var basic_case = try CPUTester.init(.CLV(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.overflow = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.flags.overflow = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();
}

test "instruction operation DEC zero" {
    var basic_case = try CPUTester.init(.DEC(.zero, 0x86), &.{});
    defer basic_case.deinit();

    try basic_case.expectStartSequence();

    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x86, null);
    basic_case.fixture.data_bus = .fromInt(0x03);
    try basic_case.expectWrite(0x86, 0x03);
    try basic_case.expectWrite(0x86, 0x02);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x02);

    try basic_case.testExpected();
}

test "instruction operation DEC absolute" {
    var basic_case = try CPUTester.init(.DEC(.absolute, .fromInt(0x2386)), &.{});
    defer basic_case.deinit();

    try basic_case.expectStartSequence();

    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0x2386, null);
    basic_case.fixture.data_bus = .fromInt(0x03);
    try basic_case.expectWrite(0x2386, 0x03);
    try basic_case.expectWrite(0x2386, 0x02);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0x02);

    try basic_case.testExpected();
}

test "instruction operation DEX" {
    var basic_case = try CPUTester.init(.DEX(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.registers.x = .fromInt(0x33);
    basic_case.expected.registers.x = .fromInt(0x32);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;

    try testImplicitInternalMode(&basic_case);
    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.DEX(.implicit, {}), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.flags.zero_ = 1;
    wrap_case.fixture.flags.negative = 0;
    wrap_case.fixture.registers.x = .fromInt(0x00);
    wrap_case.expected.registers.x = .fromInt(0xff);
    wrap_case.expected.flags.zero_ = 0;
    wrap_case.expected.flags.negative = 1;

    try testImplicitInternalMode(&wrap_case);
    try wrap_case.testExpected();

    var zero_case = try CPUTester.init(.DEX(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.negative = 1;
    zero_case.fixture.registers.x = .fromInt(0x01);
    zero_case.expected.registers.x = .fromInt(0x00);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.negative = 0;

    try testImplicitInternalMode(&zero_case);
    try zero_case.testExpected();
}

test "instruction operation DEY implicit" {
    var basic_case = try CPUTester.init(.DEY(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.y = .fromInt(0x02);
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.zero_ = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.y = .fromInt(0x01);
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.DEY(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.y = .fromInt(0x00);
    negative_case.fixture.flags.negative = 0;
    negative_case.fixture.flags.zero_ = 1;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.y = .fromInt(0xff);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.data_bus = .fromInt(0xea);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.DEY(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.y = .fromInt(0x01);
    zero_case.fixture.flags.negative = 1;
    zero_case.fixture.flags.zero_ = 0;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.y = .fromInt(0x00);
    zero_case.expected.flags.negative = 0;
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.data_bus = .fromInt(0xea);

    try zero_case.testExpected();
}

test "instruction operation EOR immediate" {
    var basic_case = try CPUTester.init(.EOR(.immediate, 0b10101010), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100101);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.EOR(.immediate, 0b10101010), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0b00001111);

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0b10100101);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xaa);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.EOR(.immediate, 0b10101010), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0b10101010);

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.data_bus = .fromInt(0xaa);

    try zero_case.testExpected();
}

test "instruction operation EOR zero" {
    var basic_case = try CPUTester.init(.EOR(.zero, 0xae), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0xae, null);
    basic_case.fixture.data_bus = .fromInt(0b10101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100101);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();
}

test "instruction operation EOR indexed zero x" {
    var basic_case = try CPUTester.init(.EOR(.indexed_zero_x, 0xae), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);
    basic_case.fixture.registers.x = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0xae, null);
    try basic_case.expectRead(0xae + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0b10101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100101);
    basic_case.expected.registers.x = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();
}

test "instruction operation EOR absolute" {
    var basic_case = try CPUTester.init(.EOR(.absolute, .fromInt(0xee55)), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xee55, null);
    basic_case.fixture.data_bus = .fromInt(0b10101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100101);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();
}

test "instruction operation EOR indexed absolute x" {
    var basic_case = try CPUTester.init(.EOR(.indexed_absolute_x, .fromInt(0xee55)), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);
    basic_case.fixture.registers.x = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xee55 + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0b10101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100101);
    basic_case.expected.registers.x = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();

    var page_fetch_case = try CPUTester.init(.EOR(.indexed_absolute_x, .fromInt(0xeef5)), &.{});
    defer page_fetch_case.deinit();

    page_fetch_case.fixture.registers.a = .fromInt(0b10001111);
    page_fetch_case.fixture.registers.x = .fromInt(0x10);

    try page_fetch_case.expectStartSequence();
    try page_fetch_case.expectRead(0, page_fetch_case.program);
    try page_fetch_case.expectRead(1, page_fetch_case.program);
    try page_fetch_case.expectRead(2, page_fetch_case.program);
    try page_fetch_case.expectRead(0xef05, null);
    try page_fetch_case.expectRead(0xef05, null);
    page_fetch_case.fixture.data_bus = .fromInt(0b10101010);
    try page_fetch_case.expectExecute();

    page_fetch_case.expected.registers.a = .fromInt(0b00100101);
    page_fetch_case.expected.registers.x = .fromInt(0x10);
    page_fetch_case.expected.data_bus = .fromInt(0xaa);
    page_fetch_case.expected.clock_cycles += 1;

    try page_fetch_case.testExpected();
}

test "instruction operation EOR indexed absolute y" {
    var basic_case = try CPUTester.init(.EOR(.indexed_absolute_y, .fromInt(0xee55)), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);
    basic_case.fixture.registers.y = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(2, basic_case.program);
    try basic_case.expectRead(0xee55 + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0b10101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100101);
    basic_case.expected.registers.y = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();

    var page_fetch_case = try CPUTester.init(.EOR(.indexed_absolute_y, .fromInt(0xeef5)), &.{});
    defer page_fetch_case.deinit();

    page_fetch_case.fixture.registers.a = .fromInt(0b10001111);
    page_fetch_case.fixture.registers.y = .fromInt(0x10);

    try page_fetch_case.expectStartSequence();
    try page_fetch_case.expectRead(0, page_fetch_case.program);
    try page_fetch_case.expectRead(1, page_fetch_case.program);
    try page_fetch_case.expectRead(2, page_fetch_case.program);
    try page_fetch_case.expectRead(0xef05, null);
    try page_fetch_case.expectRead(0xef05, null);
    page_fetch_case.fixture.data_bus = .fromInt(0b10101010);
    try page_fetch_case.expectExecute();

    page_fetch_case.expected.registers.a = .fromInt(0b00100101);
    page_fetch_case.expected.registers.y = .fromInt(0x10);
    page_fetch_case.expected.data_bus = .fromInt(0xaa);
    page_fetch_case.expected.clock_cycles += 1;

    try page_fetch_case.testExpected();
}

test "instruction operation EOR pre indexed indirect zero x" {
    var basic_case = try CPUTester.init(.EOR(.pre_indexed_indirect_zero_x, 0xcd), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);
    basic_case.fixture.registers.x = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x00cd, null);
    try basic_case.expectRead(0x00d0, null);
    basic_case.fixture.data_bus = .fromInt(0xce);
    try basic_case.expectRead(0x00d1, null);
    basic_case.fixture.data_bus = .fromInt(0x35);
    try basic_case.expectRead(0x35ce, null);
    basic_case.fixture.data_bus = .fromInt(0b10101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100101);
    basic_case.expected.registers.x = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.EOR(.pre_indexed_indirect_zero_x, 0xff), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.registers.a = .fromInt(0b10001111);
    wrap_case.fixture.registers.x = .fromInt(0x10);

    try wrap_case.expectStartSequence();
    try wrap_case.expectRead(0, wrap_case.program);
    try wrap_case.expectRead(1, wrap_case.program);
    try wrap_case.expectRead(0x00ff, null);
    try wrap_case.expectRead(0x000f, null);
    wrap_case.fixture.data_bus = .fromInt(0xce);
    try wrap_case.expectRead(0x0010, null);
    wrap_case.fixture.data_bus = .fromInt(0x35);
    try wrap_case.expectRead(0x35ce, null);
    wrap_case.fixture.data_bus = .fromInt(0b10101010);
    try wrap_case.expectExecute();

    wrap_case.expected.registers.a = .fromInt(0b00100101);
    wrap_case.expected.registers.x = .fromInt(0x10);
    wrap_case.expected.data_bus = .fromInt(0xaa);

    try wrap_case.testExpected();

    var wrap_add_one_case = try CPUTester.init(.EOR(.pre_indexed_indirect_zero_x, 0xef), &.{});
    defer wrap_add_one_case.deinit();

    wrap_add_one_case.fixture.registers.a = .fromInt(0b10001111);
    wrap_add_one_case.fixture.registers.x = .fromInt(0x10);

    try wrap_add_one_case.expectStartSequence();
    try wrap_add_one_case.expectRead(0, wrap_add_one_case.program);
    try wrap_add_one_case.expectRead(1, wrap_add_one_case.program);
    try wrap_add_one_case.expectRead(0x00ef, null);
    try wrap_add_one_case.expectRead(0x00ff, null);
    wrap_add_one_case.fixture.data_bus = .fromInt(0xce);
    try wrap_add_one_case.expectRead(0x0000, null);
    wrap_add_one_case.fixture.data_bus = .fromInt(0x35);
    try wrap_add_one_case.expectRead(0x35ce, null);
    wrap_add_one_case.fixture.data_bus = .fromInt(0b10101010);
    try wrap_add_one_case.expectExecute();

    wrap_add_one_case.expected.registers.a = .fromInt(0b00100101);
    wrap_add_one_case.expected.registers.x = .fromInt(0x10);
    wrap_add_one_case.expected.data_bus = .fromInt(0xaa);

    try wrap_add_one_case.testExpected();
}

test "instruction operation EOR post indexed indirect zero y" {
    var basic_case = try CPUTester.init(.EOR(.post_indexed_indirect_zero_y, 0xcd), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);
    basic_case.fixture.registers.y = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x00cd, null);
    basic_case.fixture.data_bus = .fromInt(0xce);
    try basic_case.expectRead(0x00ce, null);
    basic_case.fixture.data_bus = .fromInt(0x35);
    try basic_case.expectRead(0x35ce + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0b10101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100101);
    basic_case.expected.registers.y = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();

    var page_fetch_case = try CPUTester.init(.EOR(.post_indexed_indirect_zero_y, 0xcd), &.{});
    defer page_fetch_case.deinit();

    page_fetch_case.fixture.registers.a = .fromInt(0b10001111);
    page_fetch_case.fixture.registers.y = .fromInt(0x3);

    try page_fetch_case.expectStartSequence();
    try page_fetch_case.expectRead(0, page_fetch_case.program);
    try page_fetch_case.expectRead(1, page_fetch_case.program);
    try page_fetch_case.expectRead(0x00cd, null);
    page_fetch_case.fixture.data_bus = .fromInt(0xff);
    try page_fetch_case.expectRead(0x00ce, null);
    page_fetch_case.fixture.data_bus = .fromInt(0x35);
    try page_fetch_case.expectRead(0x35ff + 0x3, null);
    try page_fetch_case.expectRead(0x35ff + 0x3, null);
    page_fetch_case.fixture.data_bus = .fromInt(0b10101010);
    try page_fetch_case.expectExecute();

    page_fetch_case.expected.registers.a = .fromInt(0b00100101);
    page_fetch_case.expected.registers.y = .fromInt(0x3);
    page_fetch_case.expected.data_bus = .fromInt(0xaa);
    page_fetch_case.expected.clock_cycles += 1;

    try page_fetch_case.testExpected();
}

test "instruction operation CMP immediate" {
    var basic_case = try CPUTester.init(.CMP(.immediate, 0b00010000), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b10001111);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b10001111);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.carry = 1;
    basic_case.expected.data_bus = .fromInt(0b00010000);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.CMP(.immediate, 0b01000000), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0b00001111);

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0b00001111);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0b01000000);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.CMP(.immediate, 0b10101010), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0b10101010);

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0b10101010);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.carry = 1;
    zero_case.expected.data_bus = .fromInt(0xaa);

    try zero_case.testExpected();
}

test "instruction operation ORA post indexed indirect zero y" {
    var basic_case = try CPUTester.init(.ORA(.post_indexed_indirect_zero_y, 0xcd), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b00001001);
    basic_case.fixture.registers.y = .fromInt(0x3);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x00cd, null);
    basic_case.fixture.data_bus = .fromInt(0xce);
    try basic_case.expectRead(0x00ce, null);
    basic_case.fixture.data_bus = .fromInt(0x35);
    try basic_case.expectRead(0x35ce + 0x3, null);
    basic_case.fixture.data_bus = .fromInt(0b00101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00101011);
    basic_case.expected.registers.y = .fromInt(0x3);
    basic_case.expected.data_bus = .fromInt(0x2a);

    try basic_case.testExpected();
}

test "instruction operation LDX immediate" {
    var basic_case = try CPUTester.init(.LDX(.immediate, 0b00101010), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.x = .fromInt(0b10001111);
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.zero_ = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.x = .fromInt(0b00101010);
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.data_bus = .fromInt(0b00101010);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.LDX(.immediate, 0b10101010), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.x = .fromInt(0b00001111);

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.x = .fromInt(0b10101010);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xaa);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.LDX(.immediate, 0x0), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.x = .fromInt(0b10101010);

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.x = .fromInt(0);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.data_bus = .fromInt(0x0);

    try zero_case.testExpected();
}

test "instruction operation LDX indexed zero y" {
    var basic_case = try CPUTester.init(.LDX(.indexed_zero_y, 0xd5), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.x = .fromInt(0x39);
    basic_case.fixture.registers.y = .fromInt(0x1f);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x00d5, null);
    try basic_case.expectRead(0x00f4, null);
    basic_case.fixture.data_bus = .fromInt(0x7c);
    try basic_case.expectExecute();

    basic_case.expected.registers.x = .fromInt(0x7c);
    basic_case.expected.registers.y = .fromInt(0x1f);
    basic_case.expected.data_bus = .fromInt(0x7c);

    try basic_case.testExpected();

    var wrap_case = try CPUTester.init(.LDX(.indexed_zero_y, 0xe5), &.{});
    defer wrap_case.deinit();

    wrap_case.fixture.registers.x = .fromInt(0x39);
    wrap_case.fixture.registers.y = .fromInt(0x1f);

    try wrap_case.expectStartSequence();
    try wrap_case.expectRead(0, wrap_case.program);
    try wrap_case.expectRead(1, wrap_case.program);
    try wrap_case.expectRead(0x00e5, null);
    try wrap_case.expectRead(0x0004, null);
    wrap_case.fixture.data_bus = .fromInt(0x7c);
    try wrap_case.expectExecute();

    wrap_case.expected.registers.x = .fromInt(0x7c);
    wrap_case.expected.registers.y = .fromInt(0x1f);
    wrap_case.expected.data_bus = .fromInt(0x7c);

    try wrap_case.testExpected();
}

test "instruction operation LDY immediate" {
    var basic_case = try CPUTester.init(.LDY(.immediate, 0b00101010), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.y = .fromInt(0b10001111);
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.zero_ = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.y = .fromInt(0b00101010);
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.data_bus = .fromInt(0b00101010);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.LDY(.immediate, 0b10101010), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.y = .fromInt(0b00001111);

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.y = .fromInt(0b10101010);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xaa);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.LDY(.immediate, 0x0), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.y = .fromInt(0b10101010);

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.y = .fromInt(0);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.data_bus = .fromInt(0x0);

    try zero_case.testExpected();
}

test "instruction operation AND immediate" {
    var basic_case = try CPUTester.init(.AND(.immediate, 0b10101010), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b00001111);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00001010);
    basic_case.expected.data_bus = .fromInt(0xaa);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.AND(.immediate, 0b10101010), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0b10001111);

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0b10001010);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xaa);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.AND(.immediate, 0b10101010), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0b01010101);

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.data_bus = .fromInt(0xaa);

    try zero_case.testExpected();
}

test "instruction operation CPX immediate" {
    var basic_case = try CPUTester.init(.CPX(.immediate, 0b00010000), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.x = .fromInt(0b10001111);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.x = .fromInt(0b10001111);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.carry = 1;
    basic_case.expected.data_bus = .fromInt(0b00010000);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.CPX(.immediate, 0b01000000), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.x = .fromInt(0b00001111);

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.x = .fromInt(0b00001111);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0b01000000);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.CPX(.immediate, 0b10101010), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.x = .fromInt(0b10101010);

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.x = .fromInt(0b10101010);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.carry = 1;
    zero_case.expected.data_bus = .fromInt(0xaa);

    try zero_case.testExpected();
}

test "instruction operation CPY immediate" {
    var basic_case = try CPUTester.init(.CPY(.immediate, 0b00010000), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.y = .fromInt(0b10001111);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.y = .fromInt(0b10001111);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.carry = 1;
    basic_case.expected.data_bus = .fromInt(0b00010000);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.CPY(.immediate, 0b01000000), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.y = .fromInt(0b00001111);

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.y = .fromInt(0b00001111);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0b01000000);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.CPY(.immediate, 0b10101010), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.y = .fromInt(0b10101010);

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.y = .fromInt(0b10101010);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.carry = 1;
    zero_case.expected.data_bus = .fromInt(0xaa);

    try zero_case.testExpected();
}

test "instruction operation ORA immediate" {
    var basic_case = try CPUTester.init(.ORA(.immediate, 0b00101010), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b00001111);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00101111);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.data_bus = .fromInt(0b00101010);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.ORA(.immediate, 0b10101010), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0b00001111);

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0b10101111);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xaa);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.ORA(.immediate, 0x0), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0x0);

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.data_bus = .fromInt(0x0);

    try zero_case.testExpected();
}

test "instruction operation BIT zero" {
    var basic_case = try CPUTester.init(.BIT(.zero, 0xee), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b00001111);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.overflow = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0xee, null);
    basic_case.fixture.data_bus = .fromInt(0b00101010);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00001111);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.overflow = 0;
    basic_case.expected.data_bus = .fromInt(0b00101010);

    try basic_case.testExpected();

    var overflow_case = try CPUTester.init(.BIT(.zero, 0xee), &.{});
    defer overflow_case.deinit();

    overflow_case.fixture.registers.a = .fromInt(0b00001111);
    overflow_case.fixture.flags.zero_ = 1;
    overflow_case.fixture.flags.negative = 1;
    overflow_case.fixture.flags.overflow = 0;

    try overflow_case.expectStartSequence();
    try overflow_case.expectRead(0, overflow_case.program);
    try overflow_case.expectRead(1, overflow_case.program);
    try overflow_case.expectRead(0xee, null);
    overflow_case.fixture.data_bus = .fromInt(0b01101010);
    try overflow_case.expectExecute();

    overflow_case.expected.registers.a = .fromInt(0b00001111);
    overflow_case.expected.flags.zero_ = 0;
    overflow_case.expected.flags.negative = 0;
    overflow_case.expected.flags.overflow = 1;
    overflow_case.expected.data_bus = .fromInt(0b01101010);

    try overflow_case.testExpected();

    var negative_case = try CPUTester.init(.BIT(.zero, 0xee), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0b00001111);
    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.negative = 0;
    negative_case.fixture.flags.overflow = 1;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectRead(0xee, null);
    negative_case.fixture.data_bus = .fromInt(0b10101010);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0b00001111);
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.negative = 1;
    negative_case.expected.flags.overflow = 0;
    negative_case.expected.data_bus = .fromInt(0b10101010);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.BIT(.zero, 0xee), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0b11110000);
    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.negative = 1;
    zero_case.fixture.flags.overflow = 1;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectRead(0xee, null);
    zero_case.fixture.data_bus = .fromInt(0b00001111);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0b11110000);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.negative = 0;
    zero_case.expected.flags.overflow = 0;
    zero_case.expected.data_bus = .fromInt(0b00001111);

    try zero_case.testExpected();

    var all_set_case = try CPUTester.init(.BIT(.zero, 0xee), &.{});
    defer all_set_case.deinit();

    all_set_case.fixture.registers.a = .fromInt(0b00111111);
    all_set_case.fixture.flags.zero_ = 0;
    all_set_case.fixture.flags.negative = 0;
    all_set_case.fixture.flags.overflow = 0;

    try all_set_case.expectStartSequence();
    try all_set_case.expectRead(0, all_set_case.program);
    try all_set_case.expectRead(1, all_set_case.program);
    try all_set_case.expectRead(0xee, null);
    all_set_case.fixture.data_bus = .fromInt(0b11000000);
    try all_set_case.expectExecute();

    all_set_case.expected.registers.a = .fromInt(0b00111111);
    all_set_case.expected.flags.zero_ = 1;
    all_set_case.expected.flags.negative = 1;
    all_set_case.expected.flags.overflow = 1;
    all_set_case.expected.data_bus = .fromInt(0b11000000);

    try all_set_case.testExpected();
}

test "instruction operation LSR implicit" {
    var basic_case = try CPUTester.init(.LSR(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b01001000);
    basic_case.fixture.flags.carry = 1;
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.zero_ = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00100100);
    basic_case.expected.flags.carry = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var zero_and_carry_case = try CPUTester.init(.LSR(.implicit, {}), &.{});
    defer zero_and_carry_case.deinit();

    zero_and_carry_case.fixture.registers.a = .fromInt(0b00000001);
    zero_and_carry_case.fixture.flags.carry = 0;
    zero_and_carry_case.fixture.flags.negative = 1;
    zero_and_carry_case.fixture.flags.zero_ = 0;

    try zero_and_carry_case.expectStartSequence();
    try zero_and_carry_case.expectRead(0, zero_and_carry_case.program);
    try zero_and_carry_case.expectRead(1, zero_and_carry_case.program);
    try zero_and_carry_case.expectExecute();

    zero_and_carry_case.expected.registers.a = .fromInt(0b00000000);
    zero_and_carry_case.expected.flags.carry = 1;
    zero_and_carry_case.expected.flags.negative = 0;
    zero_and_carry_case.expected.flags.zero_ = 1;
    zero_and_carry_case.expected.data_bus = .fromInt(0xea);

    try zero_and_carry_case.testExpected();
}

test "instruction operation NOP implicit" {
    var basic_case = try CPUTester.init(.NOP(.implicit, {}), &.{});
    defer basic_case.deinit();

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();
}

test "instruction operation PHA implicit" {
    var basic_case = try CPUTester.init(.PHA(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x55);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectWrite(0x1ff, 0x55);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0x55);
    basic_case.expected.registers.s = .fromInt(0xfe);
    basic_case.expected.data_bus = .fromInt(0x55);

    try basic_case.testExpected();
}

test "instruction operation PHP implicit" {
    var basic_case = try CPUTester.init(.PHP(.implicit, {}), &.{});
    defer basic_case.deinit();

    try basic_case.expectStartSequence();
    basic_case.fixture.flags = @bitCast(@as(u8, 0b11001010));
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectWrite(0x1ff, @bitCast(@as(u8, 0b11001010)));
    try basic_case.expectExecute();

    basic_case.expected.registers.s = .fromInt(0xfe);
    basic_case.expected.flags = @bitCast(@as(u8, 0b11001010));
    basic_case.expected.data_bus = .fromInt(0b11001010);

    try basic_case.testExpected();
}

test "instruction operation PLA implicit" {
    var basic_case = try CPUTester.init(.PLA(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.s = .fromInt(0xf0);
    basic_case.fixture.registers.a = .fromInt(0x12);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x1f0, null);
    try basic_case.expectRead(0x1f1, null);
    basic_case.fixture.data_bus = .fromInt(0x55);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0x55);
    basic_case.expected.registers.s = .fromInt(0xf1);
    basic_case.expected.data_bus = .fromInt(0x55);

    try basic_case.testExpected();
}

test "instruction operation PLP implicit" {
    var basic_case = try CPUTester.init(.PLP(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.s = .fromInt(0xf0);

    try basic_case.expectStartSequence();
    basic_case.fixture.flags = @bitCast(@as(u8, 0b11001010));
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x1f0, null);
    try basic_case.expectRead(0x1f1, null);
    basic_case.fixture.data_bus = .fromInt(0b00110101);
    try basic_case.expectExecute();

    basic_case.expected.registers.s = .fromInt(0xf1);
    basic_case.expected.flags = @bitCast(@as(u8, 0b00000101));
    basic_case.expected.data_bus = .fromInt(0b00110101);

    try basic_case.testExpected();
}

test "instruction operation ROL implicit" {
    var basic_case = try CPUTester.init(.ROL(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b00100100);
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.carry = 0;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b01001000);
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.carry = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var carry_in_case = try CPUTester.init(.ROL(.implicit, {}), &.{});
    defer carry_in_case.deinit();

    carry_in_case.fixture.registers.a = .fromInt(0b00100100);
    carry_in_case.fixture.flags.negative = 1;
    carry_in_case.fixture.flags.zero_ = 1;
    carry_in_case.fixture.flags.carry = 1;

    try carry_in_case.expectStartSequence();
    try carry_in_case.expectRead(0, carry_in_case.program);
    try carry_in_case.expectRead(1, carry_in_case.program);
    try carry_in_case.expectExecute();

    carry_in_case.expected.registers.a = .fromInt(0b01001001);
    carry_in_case.expected.flags.negative = 0;
    carry_in_case.expected.flags.zero_ = 0;
    carry_in_case.expected.flags.carry = 0;
    carry_in_case.expected.data_bus = .fromInt(0xea);

    try carry_in_case.testExpected();

    var carry_out_case = try CPUTester.init(.ROL(.implicit, {}), &.{});
    defer carry_out_case.deinit();

    carry_out_case.fixture.registers.a = .fromInt(0b10100100);
    carry_out_case.fixture.flags.negative = 1;
    carry_out_case.fixture.flags.zero_ = 1;
    carry_out_case.fixture.flags.carry = 0;

    try carry_out_case.expectStartSequence();
    try carry_out_case.expectRead(0, carry_out_case.program);
    try carry_out_case.expectRead(1, carry_out_case.program);
    try carry_out_case.expectExecute();

    carry_out_case.expected.registers.a = .fromInt(0b01001000);
    carry_out_case.expected.flags.negative = 0;
    carry_out_case.expected.flags.zero_ = 0;
    carry_out_case.expected.flags.carry = 1;
    carry_out_case.expected.data_bus = .fromInt(0xea);

    try carry_out_case.testExpected();

    var negative_case = try CPUTester.init(.ROL(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0b01100100);
    negative_case.fixture.flags.negative = 0;
    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.carry = 0;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0b11001000);
    negative_case.expected.flags.negative = 1;
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.carry = 0;
    negative_case.expected.data_bus = .fromInt(0xea);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.ROL(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0b10000000);
    zero_case.fixture.flags.negative = 1;
    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.carry = 0;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0b00000000);
    zero_case.expected.flags.negative = 0;
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.carry = 1;
    zero_case.expected.data_bus = .fromInt(0xea);

    try zero_case.testExpected();
}

test "instruction operation ROR implicit" {
    var basic_case = try CPUTester.init(.ROR(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0b00100100);
    basic_case.fixture.flags.negative = 1;
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.carry = 0;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0b00010010);
    basic_case.expected.flags.negative = 0;
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.carry = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var carry_in_case = try CPUTester.init(.ROR(.implicit, {}), &.{});
    defer carry_in_case.deinit();

    carry_in_case.fixture.registers.a = .fromInt(0b00100100);
    carry_in_case.fixture.flags.negative = 0;
    carry_in_case.fixture.flags.zero_ = 1;
    carry_in_case.fixture.flags.carry = 1;

    try carry_in_case.expectStartSequence();
    try carry_in_case.expectRead(0, carry_in_case.program);
    try carry_in_case.expectRead(1, carry_in_case.program);
    try carry_in_case.expectExecute();

    carry_in_case.expected.registers.a = .fromInt(0b10010010);
    carry_in_case.expected.flags.negative = 1;
    carry_in_case.expected.flags.zero_ = 0;
    carry_in_case.expected.flags.carry = 0;
    carry_in_case.expected.data_bus = .fromInt(0xea);

    try carry_in_case.testExpected();

    var carry_out_case = try CPUTester.init(.ROR(.implicit, {}), &.{});
    defer carry_out_case.deinit();

    carry_out_case.fixture.registers.a = .fromInt(0b00100101);
    carry_out_case.fixture.flags.negative = 1;
    carry_out_case.fixture.flags.zero_ = 1;
    carry_out_case.fixture.flags.carry = 0;

    try carry_out_case.expectStartSequence();
    try carry_out_case.expectRead(0, carry_out_case.program);
    try carry_out_case.expectRead(1, carry_out_case.program);
    try carry_out_case.expectExecute();

    carry_out_case.expected.registers.a = .fromInt(0b00010010);
    carry_out_case.expected.flags.negative = 0;
    carry_out_case.expected.flags.zero_ = 0;
    carry_out_case.expected.flags.carry = 1;
    carry_out_case.expected.data_bus = .fromInt(0xea);

    try carry_out_case.testExpected();

    var zero_case = try CPUTester.init(.ROR(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0b00000001);
    zero_case.fixture.flags.negative = 1;
    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.carry = 0;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0b00000000);
    zero_case.expected.flags.negative = 0;
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.carry = 1;
    zero_case.expected.data_bus = .fromInt(0xea);

    try zero_case.testExpected();
}

test "instruction operation RTI implicit" {
    var basic_case = try CPUTester.init(.RTI(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.s = .fromInt(0xf0);

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectRead(0x1f0, null);
    try basic_case.expectRead(0x1f1, null);
    basic_case.fixture.data_bus = .fromInt(0b11111010);
    try basic_case.expectRead(0x1f2, null);
    basic_case.fixture.data_bus = .fromInt(0x36);
    try basic_case.expectRead(0x1f3, null);
    basic_case.fixture.data_bus = .fromInt(0xf7);
    try basic_case.expectExecute();

    basic_case.expected.registers.s = .fromInt(0xf3);
    basic_case.expected.flags = @bitCast(@as(u8, 0b11001010));
    basic_case.expected.address_bus = .fromInt(0xf736);
    basic_case.expected.registers.pc = .fromInt(0xf737);
    basic_case.expected.data_bus = .fromInt(0xf7);

    try basic_case.testExpected();
}

test "instruction operation SEC implicit" {
    var basic_case = try CPUTester.init(.SEC(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.carry = 0;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.flags.carry = 1;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();
}

test "instruction operation SED implicit" {
    var basic_case = try CPUTester.init(.SED(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.decimal_mode = 0;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.flags.decimal_mode = 1;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();
}

test "instruction operation SEI implicit" {
    var basic_case = try CPUTester.init(.SEI(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.flags.irq_disable = 0;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.flags.irq_disable = 1;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();
}

test "instruction operation TAX implicit" {
    var basic_case = try CPUTester.init(.TAX(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x5f);
    basic_case.fixture.registers.x = .fromInt(0x13);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0x5f);
    basic_case.expected.registers.x = .fromInt(0x5f);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.TAX(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0x8f);
    negative_case.fixture.registers.x = .fromInt(0x13);
    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.negative = 0;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0x8f);
    negative_case.expected.registers.x = .fromInt(0x8f);
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xea);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.TAX(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0x00);
    zero_case.fixture.registers.x = .fromInt(0x13);
    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.negative = 1;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0x00);
    zero_case.expected.registers.x = .fromInt(0x00);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.negative = 0;
    zero_case.expected.data_bus = .fromInt(0xea);

    try zero_case.testExpected();
}

test "instruction operation TAY implicit" {
    var basic_case = try CPUTester.init(.TAY(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.a = .fromInt(0x5f);
    basic_case.fixture.registers.y = .fromInt(0x13);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.a = .fromInt(0x5f);
    basic_case.expected.registers.y = .fromInt(0x5f);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.TAY(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.a = .fromInt(0x8f);
    negative_case.fixture.registers.y = .fromInt(0x13);
    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.negative = 0;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.a = .fromInt(0x8f);
    negative_case.expected.registers.y = .fromInt(0x8f);
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xea);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.TAY(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.a = .fromInt(0x00);
    zero_case.fixture.registers.y = .fromInt(0x13);
    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.negative = 1;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.a = .fromInt(0x00);
    zero_case.expected.registers.y = .fromInt(0x00);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.negative = 0;
    zero_case.expected.data_bus = .fromInt(0xea);

    try zero_case.testExpected();
}

test "instruction operation TSX implicit" {
    var basic_case = try CPUTester.init(.TSX(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.s = .fromInt(0x5f);
    basic_case.fixture.registers.x = .fromInt(0x13);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.s = .fromInt(0x5f);
    basic_case.expected.registers.x = .fromInt(0x5f);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.TSX(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.s = .fromInt(0x8f);
    negative_case.fixture.registers.x = .fromInt(0x13);
    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.negative = 0;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.s = .fromInt(0x8f);
    negative_case.expected.registers.x = .fromInt(0x8f);
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xea);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.TSX(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.s = .fromInt(0x00);
    zero_case.fixture.registers.x = .fromInt(0x13);
    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.negative = 1;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.s = .fromInt(0x00);
    zero_case.expected.registers.x = .fromInt(0x00);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.negative = 0;
    zero_case.expected.data_bus = .fromInt(0xea);

    try zero_case.testExpected();
}

test "instruction operation TXA implicit" {
    var basic_case = try CPUTester.init(.TXA(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.x = .fromInt(0x5f);
    basic_case.fixture.registers.a = .fromInt(0x13);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.x = .fromInt(0x5f);
    basic_case.expected.registers.a = .fromInt(0x5f);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.TXA(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.x = .fromInt(0x8f);
    negative_case.fixture.registers.a = .fromInt(0x13);
    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.negative = 0;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.x = .fromInt(0x8f);
    negative_case.expected.registers.a = .fromInt(0x8f);
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xea);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.TXA(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.x = .fromInt(0x00);
    zero_case.fixture.registers.a = .fromInt(0x13);
    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.negative = 1;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.x = .fromInt(0x00);
    zero_case.expected.registers.a = .fromInt(0x00);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.negative = 0;
    zero_case.expected.data_bus = .fromInt(0xea);

    try zero_case.testExpected();
}

test "instruction operation TYA implicit" {
    var basic_case = try CPUTester.init(.TYA(.implicit, {}), &.{});
    defer basic_case.deinit();

    basic_case.fixture.registers.y = .fromInt(0x5f);
    basic_case.fixture.registers.a = .fromInt(0x13);
    basic_case.fixture.flags.zero_ = 1;
    basic_case.fixture.flags.negative = 1;

    try basic_case.expectStartSequence();
    try basic_case.expectRead(0, basic_case.program);
    try basic_case.expectRead(1, basic_case.program);
    try basic_case.expectExecute();

    basic_case.expected.registers.y = .fromInt(0x5f);
    basic_case.expected.registers.a = .fromInt(0x5f);
    basic_case.expected.flags.zero_ = 0;
    basic_case.expected.flags.negative = 0;
    basic_case.expected.data_bus = .fromInt(0xea);

    try basic_case.testExpected();

    var negative_case = try CPUTester.init(.TYA(.implicit, {}), &.{});
    defer negative_case.deinit();

    negative_case.fixture.registers.y = .fromInt(0x8f);
    negative_case.fixture.registers.a = .fromInt(0x13);
    negative_case.fixture.flags.zero_ = 1;
    negative_case.fixture.flags.negative = 0;

    try negative_case.expectStartSequence();
    try negative_case.expectRead(0, negative_case.program);
    try negative_case.expectRead(1, negative_case.program);
    try negative_case.expectExecute();

    negative_case.expected.registers.y = .fromInt(0x8f);
    negative_case.expected.registers.a = .fromInt(0x8f);
    negative_case.expected.flags.zero_ = 0;
    negative_case.expected.flags.negative = 1;
    negative_case.expected.data_bus = .fromInt(0xea);

    try negative_case.testExpected();

    var zero_case = try CPUTester.init(.TYA(.implicit, {}), &.{});
    defer zero_case.deinit();

    zero_case.fixture.registers.y = .fromInt(0x00);
    zero_case.fixture.registers.a = .fromInt(0x13);
    zero_case.fixture.flags.zero_ = 0;
    zero_case.fixture.flags.negative = 1;

    try zero_case.expectStartSequence();
    try zero_case.expectRead(0, zero_case.program);
    try zero_case.expectRead(1, zero_case.program);
    try zero_case.expectExecute();

    zero_case.expected.registers.y = .fromInt(0x00);
    zero_case.expected.registers.a = .fromInt(0x00);
    zero_case.expected.flags.zero_ = 1;
    zero_case.expected.flags.negative = 0;
    zero_case.expected.data_bus = .fromInt(0xea);

    try zero_case.testExpected();
}

// Test Groups:

// Done:

// ({rti, rts, brk, read, rmw, stack_push, stack_pull} + implicit)
// (read + immediate)
// ({read, store, rmw} + zero)
// ({read, store, rmw} + indexed_zero_x)
// ({read, store} + indexed_zero_y)
// ({read, store, rmw, jsr, jmp} + absolute)
// ({read, store, rmw} + indexed_absolute_x)
// ({read, store} + indexed_absolute_y)
// (jmp + indirect_absolute)
// ({read, store} + post_indexed_indirect_zero_y)
// ({read, store} + pre_indexed_indirect_zero_x)
// (branch + relative)

const CpuFormatterContext = struct {
    cpu: *MOS6502,
    mode: PrintCpuMode,
};

const CpuFormatter = std.fmt.Alt(CpuFormatterContext, printCpu);
pub fn formatCpu(cpu: *MOS6502, mode: PrintCpuMode) CpuFormatter {
    return .{ .data = .{ .cpu = cpu, .mode = mode } };
}

const PrintCpuMode = enum { vml, terminal };

fn printCpu(context: CpuFormatterContext, writer: *std.Io.Writer) !void {
    const cpu = context.cpu;
    const mode = context.mode;
    try writeField("il", "cc", "{x}", cpu.clock_cycles, mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("il", "phi", "{}", cpu.inputs.clock, mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("il", "icc", "0b{b:04}", cpu.instr_cycle_count, mode, writer);
    try writer.writeByte('\n');

    try writeField("il", "db", "0b{b:08}", cpu.data_bus.toInt(), mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("il", "ir", "0x{x:02}", cpu.instruction_register.toInt(), mode, writer);
    try writer.writeByte('\n');

    try writeField("il", "rw", "{t}", cpu.read_write, mode, writer);
    try writer.writeByte('\n');

    try writeField("a", "pc", "0x{x:04}", cpu.registers.pc.toInt(), mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("a", "ab", "0x{x:04}", cpu.address_bus.toInt(), mode, writer);
    try writer.writeByte('\n');

    try writeField("rf", "a", "0b{b:08}", cpu.registers.a.toInt(), mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("rf", "s", "0b{b:08}", cpu.registers.s.toInt(), mode, writer);
    try writer.writeByte('\n');

    try writeField("rf", "x", "0b{b:08}", cpu.registers.x.toInt(), mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("rf", "y", "0b{b:08}", cpu.registers.y.toInt(), mode, writer);
    try writer.writeByte('\n');

    try writeField("rf", "n", "{}", cpu.flags.negative, mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("rf", "v", "{}", cpu.flags.overflow, mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("rf", "d", "{}", cpu.flags.decimal_mode, mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("rf", "i", "{}", cpu.flags.irq_disable, mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("rf", "z", "{}", cpu.flags.zero_, mode, writer);
    try writeEndColumn(mode, writer);
    try writeField("rf", "c", "{}", cpu.flags.carry, mode, writer);
    try writer.writeByte('\n');
}

fn writeField(comptime tag: []const u8, label: []const u8, comptime fmt: []const u8, value: anytype, mode: PrintCpuMode, writer: *std.Io.Writer) !void {
    try switch (mode) {
        .vml => writer.print("<" ++ tag ++ ">{s}</" ++ tag ++ "> : <n>" ++ fmt ++ "</n>", .{ label, value }),
        .terminal => writer.print("{s} : " ++ fmt, .{ label, value }),
    };
}

fn writeEndColumn(mode: PrintCpuMode, writer: *std.Io.Writer) !void {
    try switch (mode) {
        .vml => writer.writeAll("</ec>"),
        .terminal => writer.writeAll("\t"),
    };
}
