//! Runtime attachment identity survives restoration independently of handler IDs.
const std = @import("std");
const d = @import("horos").data;
const k = @import("kosmos");
const ir = d.activation;
const p = d.program;
const a = std.testing.allocator;
const base: ir.Program = .{
    .roots = .{ .entry = 0, .result = 0, .failure = 1 },
    .schemas = &.{
        .u64,                                  .unit, .boolean,
        .{ .internal = .{ .computation = .{
            .parameters = &.{5},
            .result = 0,
            .effects = &.{0},
            .capture_bound = &.{0},
        } } },
        .{ .internal = .{ .resumption = .{
            .effect = 0,
            .input = 0,
            .answer = 0,
            .handled = &.{0},
            .capture_bound = &.{ 0, 5 },
            .mode = .deep,
            .use = .linear,
        } } },
        .{ .internal = .{ .capability = 0 } },
    },
    .constants = &.{},
    .effects = &.{.{ .identity = "test.tail.admin", .payload = 0, .result = 0, .external = false }},
    .functions = &.{
        .{ .entry = 0, .inputs = &.{0}, .layout = .{ .slots = &.{ 0, 3, 0 } }, .result = 0 },
        .{
            .entry = 2,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 5, 0, 0 } },
            .result = 0,
            .effects = &.{0},
        },
        .{ .entry = 4, .inputs = &.{0}, .layout = .{ .slots = &.{0} }, .result = 0 },
        .{
            .entry = 5,
            .inputs = &.{ 0, 1 },
            .layout = .{ .slots = &.{ 0, 4, 0, 0 } },
            .result = 0,
        },
    },
    .blocks = &.{
        .{ .function = 0, .instructions = &.{.{
            .destination = 1,
            .opcode = .computation,
            .operands = &.{0},
            .immediate = 0,
        }}, .terminator = .{
            .handle = .{
                .handler = 0,
                .body = 1,
                .arguments = &.{},
                .state = &.{},
                .next = .{
                    .block = 1,
                    .assignments = &.{.{
                        .destination = 2,
                        .source = .returned,
                    }},
                },
            },
        } },
        .{ .function = 0, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
        .{
            .function = 1,
            .instructions = &.{},
            .terminator = .{
                .perform = .{
                    .effect = 0,
                    .capability = 1,
                    .payload = 0,
                    .next = .{
                        .block = 3,
                        .assignments = &.{.{
                            .destination = 2,
                            .source = .returned,
                        }},
                    },
                },
            },
        },
        .{ .function = 1, .instructions = &.{.{
            .destination = 3,
            .opcode = .integer_bit_not,
            .operands = &.{2},
        }}, .terminator = .{ .return_value = 3 } },
        .{ .function = 2, .instructions = &.{}, .terminator = .{ .return_value = 0 } },
        .{
            .function = 3,
            .instructions = &.{},
            .terminator = .{
                .resume_value = .{
                    .resumption = 1,
                    .argument = 0,
                    .next = .{
                        .block = 6,
                        .assignments = &.{
                            .{ .destination = 2, .source = .returned },
                            .{ .destination = 3, .source = .{ .slot = 0 } },
                        },
                    },
                },
            },
        },
        .{ .function = 3, .instructions = &.{.{
            .destination = 0,
            .opcode = .move,
            .operands = &.{2},
        }}, .terminator = .{ .jump = .{ .block = 7, .assignments = &.{ .{
            .destination = 2,
            .source = .{ .slot = 0 },
        }, .{ .destination = 0, .source = .{ .slot = 3 } } } } } },
        .{ .function = 3, .instructions = &.{}, .terminator = .{ .return_value = 2 } },
    },
    .handlers = &.{.{ .mode = .deep, .input = 0, .answer = 0, .return_function = 2, .clauses = &.{.{
        .effect = 0,
        .function = 3,
        .resumption = 4,
    }} }},
    .constructors = &.{.{ .function = 1, .capture = 0, .schema = 3 }},
    .scopes = .{ .captures = &.{.{ .fields = &.{0}, .use = .reusable }} },
};

fn fixture(allocator: std.mem.Allocator) !ir.Program {
    var result = base;
    const functions = try allocator.alloc(ir.Function, 5);
    @memcpy(functions[0..4], base.functions);
    functions[4] = .{
        .entry = 8,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 5, 5, 0, 0, 0 } },
        .result = 0,
        .effects = &.{0},
    };
    const blocks = try allocator.alloc(ir.Block, 11);
    @memcpy(blocks[0..8], base.blocks);
    blocks[2].terminator = .{ .call = .{
        .function = 4,
        .arguments = &.{ 1, 1, 0 },
        .next = base.blocks[2].terminator.perform.next,
    } };
    blocks[8] = .{
        .function = 4,
        .instructions = &.{},
        .terminator = .{
            .perform = .{
                .effect = 0,
                .capability = 0,
                .payload = 2,
                .next = .{
                    .block = 9,
                    .assignments = &.{.{
                        .destination = 3,
                        .source = .returned,
                    }},
                },
            },
        },
    };
    blocks[9] = .{
        .function = 4,
        .instructions = &.{},
        .terminator = .{
            .perform = .{
                .effect = 0,
                .capability = 1,
                .payload = 3,
                .next = .{
                    .block = 10,
                    .assignments = &.{.{
                        .destination = 4,
                        .source = .returned,
                    }},
                },
            },
        },
    };
    blocks[10] = .{ .function = 4, .instructions = &.{}, .terminator = .{ .return_value = 4 } };
    result.functions = functions;
    result.blocks = blocks;
    return result;
}
fn nestedFixture(allocator: std.mem.Allocator) !ir.Program {
    var program = try fixture(allocator);
    const schemas = try allocator.alloc(p.Schema, 7);
    @memcpy(schemas[0..6], program.schemas);
    schemas[4].internal.resumption.effects = &.{0};
    schemas[6] = .{ .internal = .{ .computation = .{
        .parameters = &.{5},
        .result = 0,
        .effects = &.{0},
        .capture_bound = &.{ 0, 5 },
    } } };
    const functions = try allocator.alloc(ir.Function, 6);
    @memcpy(functions[0..5], program.functions);
    functions[0].layout.slots = &.{ 0, 3, 0, 0 };
    functions[0].effects = &.{0};
    functions[1].layout.slots = &.{ 0, 5, 0, 0, 6, 0 };
    functions[2].inputs = &.{ 0, 1 };
    functions[2].layout.slots = &.{ 0, 0 };
    functions[3].inputs = &.{ 4, 0, 1 };
    functions[3].layout.slots = &.{ 0, 4, 0, 0, 0 };
    functions[3].effects = &.{0};
    functions[5] = .{
        .entry = 11,
        .inputs = &.{ 0, 1, 2 },
        .layout = .{ .slots = &.{ 5, 0, 5, 0 } },
        .result = 0,
        .effects = &.{0},
    };
    const blocks = try nestedBlocks(.{ .allocator = allocator, .program = program });
    const handlers = try allocator.dupe(ir.Handler, program.handlers);
    handlers[0].state = &.{0};
    handlers[0].effects = &.{0};
    program.schemas = schemas;
    program.functions = functions;
    program.blocks = blocks;
    program.handlers = handlers;
    program.constants = &.{ .{
        .schema = 0,
        .bytes = &.{ 10, 0, 0, 0, 0, 0, 0, 0 },
    }, .{ .schema = 0, .bytes = &.{ 20, 0, 0, 0, 0, 0, 0, 0 } } };
    program.effects = &.{.{ .identity = "test.tail.admin", .payload = 0, .result = 0 }};
    program.constructors = try allocator.dupe(p.Constructor, &.{ program.constructors[0], .{
        .function = 5,
        .capture = 1,
        .schema = 6,
    } });
    program.scopes.captures = try allocator.dupe(p.Capture, &.{ program.scopes.captures[0], .{
        .fields = &.{ 5, 0 },
        .use = .reusable,
    } });
    return program;
}
fn release(r: *k.Resident) void {
    if (!r.live) return;
    r.close() catch {
        const bytes = r.takeCheckpoint(a) catch |err| std.debug.panic("{s}", .{@errorName(err)});
        a.free(bytes);
    };
}
test "same-descriptor attachment alias cannot defeat fresh delimiter discharge" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var program = try nestedFixture(alloc);
    const schemas = try alloc.dupe(p.Schema, program.schemas);
    schemas[4].internal.resumption.capture_bound = &.{5};
    program.schemas = schemas;
    const blocks = try alloc.alloc(ir.Block, program.blocks.len + 1);
    @memcpy(blocks[0..program.blocks.len], program.blocks);
    blocks[13] = blocks[11];
    blocks[13].terminator.call.arguments = &.{ 2, 2, 1 };
    blocks[11].terminator = .{ .yield_value = .{ .block = 13 } };
    blocks[5].terminator.resume_value.next = .{ .block = 7, .assignments = &.{.{
        .destination = 2,
        .source = .returned,
    }} };
    program.blocks = blocks;
    var diagnostic: d.admission.Diagnostic = .{};
    var admitted = d.activation_ownership.analyzeDiagnosed(a, program, &diagnostic) catch |err| {
        std.debug.print("program rejected {t}: {any}\n", .{ err, diagnostic });
        return err;
    };
    admitted.deinit();
    const encoded = try alloc.alloc(u8, try d.program_image.encodedLength(program));
    _ = try d.program_image.encode(alloc, program, encoded);
    var prepared = try k.Prepared.init(a, encoded);
    defer prepared.deinit();
    var resident = try k.Resident.start(a, &prepared, &.{ 9, 0, 0, 0, 0, 0, 0, 0 });
    defer release(&resident);
    var pubn = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer pubn.deinit();
    var original = try d.state_image.decodeGraph(a, pubn.checkpoint.?.bytes());
    defer original.deinit();
    try d.state_admission.validateStable(a, program, original.state);
    var authentic = try k.Resident.restore(a, &prepared, pubn.checkpoint.?.bytes());
    defer release(&authentic);
    var captured = try authentic.publish(.{ .record = a }, .resume_yield, .{
        .quantum = 2,
        .checkpoint = .receipt,
    });
    defer captured.deinit();
    var captured_state = try d.state_image.decodeGraph(a, captured.checkpoint.?.bytes());
    defer captured_state.deinit();
    try d.state_admission.validateStable(a, program, captured_state.state);
    var continuation = try k.Resident.restore(a, &prepared, captured.checkpoint.?.bytes());
    defer release(&continuation);
    var finished = try continuation.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer finished.deinit();
    var expected: [8]u8 = undefined;
    std.mem.writeInt(u64, &expected, ~@as(u64, 20), .little);
    try std.testing.expectEqualSlices(u8, &expected, finished.outcome.record.record.completed);
    try rejectFreshDelimiterAlias(.{ .original = original, .alloc = alloc, .prepared = prepared });
}

fn retainedOuterCapabilityFixture(allocator: std.mem.Allocator, effectful: bool) !ir.Program {
    var program = try nestedFixture(allocator);
    const schemas = try allocator.dupe(p.Schema, program.schemas);
    schemas[4].internal.resumption.capture_bound = &.{5};
    schemas[6].internal.computation.effects = if (effectful) &.{0} else &.{};
    const functions = try allocator.alloc(ir.Function, 7);
    @memcpy(functions[0..6], program.functions);
    functions[5].layout.slots = &.{ 5, 0, 5, 5, 0 };
    functions[5].effects = if (effectful) &.{0} else &.{};
    functions[6] = .{ .entry = 15, .inputs = &.{0}, .layout = .{ .slots = &.{5} }, .result = 5 };
    const blocks = try allocator.alloc(ir.Block, 16);
    @memcpy(blocks[0..13], program.blocks);
    blocks[5].terminator.resume_value.next = .{ .block = 7, .assignments = &.{.{
        .destination = 2,
        .source = .returned,
    }} };
    blocks[11].instructions = if (effectful) &.{
        .{ .destination = 3, .opcode = .move, .operands = &.{2} },
        .{ .destination = 2, .opcode = .move, .operands = &.{0} },
    } else &.{};
    blocks[11].terminator = .{ .yield_value = .{ .block = 13 } };
    blocks[12] = .{ .function = 5, .instructions = if (effectful) &.{} else &.{.{
        .destination = 4,
        .opcode = .constant,
        .immediate = 2,
    }}, .terminator = .{ .return_value = 4 } };
    try retainedOuterCapabilityBlocks(.{ .blocks = blocks, .effectful = effectful });
    program.schemas = schemas;
    program.functions = functions;
    program.blocks = blocks;
    program.constants = try allocator.dupe(
        p.Literal,
        &.{
            program.constants[0],                                    program.constants[1],
            .{ .schema = 0, .bytes = &.{ 9, 0, 0, 0, 0, 0, 0, 0 } },
        },
    );
    return program;
}

fn restoreRetainedOuterCapability(effectful: bool) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const program = try retainedOuterCapabilityFixture(alloc, effectful);
    var diagnostic: d.admission.Diagnostic = .{};
    var admitted = d.activation_ownership.analyzeDiagnosed(a, program, &diagnostic) catch |err| {
        std.debug.print(
            "retained outer capability program rejected {t}: {any}\n",
            .{ err, diagnostic },
        );
        return err;
    };
    admitted.deinit();
    const encoded = try alloc.alloc(u8, try d.program_image.encodedLength(program));
    _ = try d.program_image.encode(alloc, program, encoded);
    var prepared = try k.Prepared.init(a, encoded);
    defer prepared.deinit();
    var resident = try k.Resident.start(a, &prepared, &.{ 9, 0, 0, 0, 0, 0, 0, 0 });
    defer release(&resident);
    var checkpoint = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
    defer checkpoint.deinit();
    var state = try d.state_image.decodeGraph(a, checkpoint.checkpoint.?.bytes());
    defer state.deinit();
    try std.testing.expectEqual(d.process_state.Status.yielded, state.state.status);
    try expectRetainedOuterIdentity(.{ .state = state });
    var uninterrupted = try resident.publish(
        .{ .record = a },
        .resume_yield,
        .{ .checkpoint = .receipt },
    );
    defer uninterrupted.deinit();
    var expected: [8]u8 = undefined;
    std.mem.writeInt(u64, &expected, ~@as(u64, if (effectful) 20 else 9), .little);
    try std.testing.expectEqualSlices(u8, &expected, uninterrupted.outcome.record.record.completed);
    d.state_admission.validateStable(a, program, state.state) catch |err| {
        std.debug.print("retained outer capability checkpoint rejected {t}\n", .{err});
        return err;
    };
    var restored = try k.Resident.restore(a, &prepared, checkpoint.checkpoint.?.bytes());
    defer release(&restored);
    var finished = try restored.publish(
        .{ .record = a },
        .resume_yield,
        .{ .checkpoint = .receipt },
    );
    defer finished.deinit();
    try std.testing.expectEqualSlices(
        u8,
        uninterrupted.outcome.record.record.completed,
        finished.outcome.record.record.completed,
    );
    try rejectRetainedOuterSubstitution(.{
        .effectful = effectful,
        .state = state,
        .alloc = alloc,
        .prepared = prepared,
    });
}

test "effect-free nested body retains an outer capability without capturing its handler" {
    try restoreRetainedOuterCapability(false);
}

test "effectful nested body retains an outer capability for an effect-free helper" {
    try restoreRetainedOuterCapability(true);
}

const PendingReturn = enum { direct, overwritten_input, nested_call };

fn pendingReturnFixture(allocator: std.mem.Allocator, mode: PendingReturn) !ir.Program {
    var program = try retainedOuterCapabilityFixture(allocator, true);
    const functions = try allocator.alloc(ir.Function, if (mode == .nested_call) 8 else 7);
    @memcpy(functions[0..7], program.functions);
    functions[6].inputs = &.{ 0, 1 };
    functions[6].layout.slots = &.{ 5, 5, 5 };
    if (mode == .nested_call) {
        functions[7] = functions[6];
        functions[7].entry = 18;
    }
    const blocks = try allocator.alloc(ir.Block, if (mode == .nested_call) 20 else 18);
    @memcpy(blocks[0..16], program.blocks);
    blocks[16] = blocks[13];
    blocks[13].terminator = .{
        .call = .{
            .function = 6,
            .arguments = &.{ 3, 0 },
            .next = .{
                .block = 16,
                .assignments = &.{.{
                    .destination = 3,
                    .source = .returned,
                }},
            },
        },
    };
    blocks[14].terminator.call.arguments = &.{ 0, 0 };
    blocks[11].terminator = .{ .jump = .{ .block = 13 } };
    const moves: []const ir.Instruction = &.{
        .{ .destination = 2, .opcode = .move, .operands = &.{0} },
        .{ .destination = 0, .opcode = .move, .operands = &.{1} },
    };
    blocks[17] = blocks[15];
    blocks[17].terminator = .{ .return_value = if (mode == .direct) 0 else 2 };
    blocks[15].instructions = if (mode == .overwritten_input) moves else &.{};
    blocks[15].terminator = .{ .yield_value = .{ .block = 17 } };
    if (mode == .nested_call) {
        blocks[15].terminator = .{
            .call = .{
                .function = 7,
                .arguments = &.{ 0, 1 },
                .next = .{
                    .block = 17,
                    .assignments = &.{.{
                        .destination = 2,
                        .source = .returned,
                    }},
                },
            },
        };
        blocks[18] = .{
            .function = 7,
            .instructions = moves,
            .terminator = .{ .yield_value = .{ .block = 19 } },
        };
        blocks[19] = .{ .function = 7, .instructions = &.{}, .terminator = .{ .return_value = 2 } };
    }
    program.functions = functions;
    program.blocks = blocks;
    return program;
}

test "saved helper returns preserve attachment identity after inputs are discarded or overwritten" {
    inline for (std.meta.tags(PendingReturn)) |mode| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const program = try pendingReturnFixture(alloc, mode);
        const encoded = try alloc.alloc(u8, try d.program_image.encodedLength(program));
        _ = try d.program_image.encode(alloc, program, encoded);
        var prepared = try k.Prepared.init(a, encoded);
        defer prepared.deinit();
        var resident = try k.Resident.start(a, &prepared, &.{ 9, 0, 0, 0, 0, 0, 0, 0 });
        defer release(&resident);
        var first = try resident.publish(.{ .record = a }, .none, .{ .checkpoint = .receipt });
        defer first.deinit();
        var state = try d.state_image.decodeGraph(a, first.checkpoint.?.bytes());
        defer state.deinit();
        try std.testing.expectEqual(d.process_state.Status.yielded, state.state.status);
        var restored = try k.Resident.restore(a, &prepared, first.checkpoint.?.bytes());
        defer release(&restored);
        var next = try resident.publish(
            .{ .record = a },
            .resume_yield,
            .{ .checkpoint = .receipt },
        );
        defer next.deinit();
        var restored_next = try restored.publish(
            .{ .record = a },
            .resume_yield,
            .{ .checkpoint = .receipt },
        );
        defer restored_next.deinit();
        try std.testing.expectEqualSlices(
            u8,
            next.checkpoint.?.bytes(),
            restored_next.checkpoint.?.bytes(),
        );
        try expectPendingReturnCompletion(.{
            .prepared = prepared,
            .next = next,
            .resident = &resident,
        });
        try rejectPendingReturnAlias(.{
            .state = state,
            .alloc = alloc,
            .prepared = prepared,
            .mode = mode,
        });
    }
}

fn nestedBlocks(c: anytype) ![]ir.Block {
    const blocks = try c.allocator.alloc(ir.Block, 13);
    @memcpy(blocks[0..11], c.program.blocks);
    blocks[0].instructions = &.{ .{
        .destination = 3,
        .opcode = .constant,
        .immediate = 0,
    }, base.blocks[0].instructions[0] };
    blocks[0].terminator.handle.state = &.{3};
    blocks[2].instructions = &.{ .{
        .destination = 5,
        .opcode = .constant,
        .immediate = 1,
    }, .{ .destination = 4, .opcode = .computation, .immediate = 1, .operands = &.{ 1, 0 } } };
    blocks[2].terminator = .{ .handle = .{
        .handler = 0,
        .body = 4,
        .arguments = &.{},
        .state = &.{5},
        .next = base.blocks[2].terminator.perform.next,
    } };
    blocks[4].terminator = .{ .return_value = 1 };
    blocks[5].terminator.resume_value.argument = 4;
    blocks[11] = .{
        .function = 5,
        .instructions = &.{},
        .terminator = .{
            .call = .{
                .function = 4,
                .arguments = &.{ 0, 2, 1 },
                .next = .{
                    .block = 12,
                    .assignments = &.{.{
                        .destination = 3,
                        .source = .returned,
                    }},
                },
            },
        },
    };
    blocks[12] = .{ .function = 5, .instructions = &.{}, .terminator = .{ .return_value = 3 } };
    return blocks;
}

fn retainedOuterCapabilityBlocks(c: anytype) !void {
    const pure_call: ir.Block = .{
        .function = 5,
        .instructions = &.{},
        .terminator = .{
            .call = .{
                .function = 6,
                .arguments = &.{0},
                .next = .{
                    .block = 12,
                    .assignments = &.{.{
                        .destination = 3,
                        .source = .returned,
                    }},
                },
            },
        },
    };
    c.blocks[13] = if (c.effectful) .{
        .function = 5,
        .instructions = &.{},
        .terminator = .{
            .perform = .{
                .effect = 0,
                .capability = 3,
                .payload = 1,
                .next = .{
                    .block = 14,
                    .assignments = &.{.{
                        .destination = 4,
                        .source = .returned,
                    }},
                },
            },
        },
    } else pure_call;
    c.blocks[14] = pure_call;
    c.blocks[15] = .{ .function = 6, .instructions = &.{}, .terminator = .{ .return_value = 0 } };
}

fn expectRetainedOuterIdentity(c: anytype) !void {
    const current = c.state.state.nodes[@intCast(c.state.state.roots.current.?.id)];
    try std.testing.expectEqual(@as(p.Id, 13), current.record.control.block);
    const inner = c.state.state.nodes[
        @intCast(current.record.control.evidence.?.id)
    ].record.attachment;
    const outer = c.state.state.nodes[@intCast(inner.outer.?.id)].record.attachment;
    try std.testing.expect(inner.handler.id != outer.handler.id);
    const inner_handler = c.state.state.nodes[@intCast(inner.handler.id)].record.handler;
    const outer_handler = c.state.state.nodes[@intCast(outer.handler.id)].record.handler;
    try std.testing.expectEqual(inner_handler.definition, outer_handler.definition);
    try std.testing.expectEqual(@as(p.Id, 0), inner_handler.state[0].schema);
    try std.testing.expectEqual(@as(p.Id, 0), outer_handler.state[0].schema);
    try std.testing.expectEqual(@as(u64, 20), std.mem.readInt(
        u64,
        &inner_handler.state[0].body.scalar,
        .little,
    ));
    try std.testing.expectEqual(@as(u64, 10), std.mem.readInt(
        u64,
        &outer_handler.state[0].body.scalar,
        .little,
    ));
    var retained_outer = false;
    for (current.activation.?.bindings) |binding| if (binding.slot == 0) {
        try std.testing.expectEqual(inner.outer.?.id, binding.value.body.reference.id);
        retained_outer = true;
    };
    try std.testing.expect(retained_outer);
}

fn rejectRetainedOuterSubstitution(c: anytype) !void {
    if (c.effectful) {
        const current = c.state.state.nodes[@intCast(c.state.state.roots.current.?.id)];
        const inner = c.state.state.nodes[
            @intCast(current.record.control.evidence.?.id)
        ].record.attachment;
        var mutated = c.state.state;
        const nodes = try c.alloc.dupe(d.process_state.Node, mutated.nodes);
        mutated.nodes = nodes;
        const frame = &nodes[@intCast(mutated.roots.current.?.id)];
        const bindings = try c.alloc.dupe(d.process_state.Binding, frame.activation.?.bindings);
        frame.activation.?.bindings = bindings;
        var changed: usize = 0;
        for (bindings) |*binding| if (binding.slot == 3) {
            try std.testing.expectEqual(
                current.record.control.evidence.?.id,
                binding.value.body.reference.id,
            );
            binding.value.body.reference = inner.outer.?;
            changed += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), changed);
        const wire = try d.state_image.serialize(c.alloc, mutated, .{ .allocate = c.alloc }, null);
        try std.testing.expectError(
            error.InvalidOwnership,
            k.Resident.restore(a, &c.prepared, wire.bytes.?),
        );
    }
}

fn rejectFreshDelimiterAlias(c: anytype) !void {
    var mutated = c.original.state;
    const nodes = try c.alloc.dupe(d.process_state.Node, mutated.nodes);
    mutated.nodes = nodes;
    const current = &nodes[@intCast(mutated.roots.current.?.id)];
    try std.testing.expectEqual(@as(p.Id, 13), current.record.control.block);
    const inner = nodes[@intCast(current.record.control.evidence.?.id)].record.attachment;
    const outer = inner.outer.?;
    const bindings = try c.alloc.dupe(d.process_state.Binding, current.activation.?.bindings);
    current.activation.?.bindings = bindings;
    var changed: usize = 0;
    for (bindings) |*binding| if (binding.slot == 2) {
        binding.value.body.reference = outer;
        changed += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), changed);
    const wire = try d.state_image.serialize(c.alloc, mutated, .{ .allocate = c.alloc }, null);
    try std.testing.expectError(
        error.InvalidOwnership,
        k.Resident.restore(a, &c.prepared, wire.bytes.?),
    );
}

fn rejectPendingReturnAlias(c: anytype) !void {
    var mutated = c.state.state;
    const nodes = try c.alloc.dupe(d.process_state.Node, mutated.nodes);
    mutated.nodes = nodes;
    const current = &nodes[@intCast(mutated.roots.current.?.id)];
    const inner = nodes[@intCast(current.record.control.evidence.?.id)].record.attachment;
    const bindings = try c.alloc.dupe(d.process_state.Binding, current.activation.?.bindings);
    current.activation.?.bindings = bindings;
    var changed: usize = 0;
    for (bindings) |*binding| if (binding.slot == (if (c.mode == .direct) @as(p.Id, 0) else 2)) {
        try std.testing.expectEqual(
            current.record.control.evidence.?.id,
            binding.value.body.reference.id,
        );
        binding.value.body.reference = inner.outer.?;
        changed += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), changed);
    const wire = try d.state_image.serialize(c.alloc, mutated, .{ .allocate = c.alloc }, null);
    try std.testing.expectError(
        error.InvalidOwnership,
        k.Resident.restore(a, &c.prepared, wire.bytes.?),
    );
}

fn expectPendingReturnCompletion(c: anytype) !void {
    var second = try k.Resident.restore(a, &c.prepared, c.next.checkpoint.?.bytes());
    defer release(&second);
    var finished = try c.resident.publish(
        .{ .record = a },
        .resume_yield,
        .{ .checkpoint = .receipt },
    );
    defer finished.deinit();
    var restored_finished = try second.publish(
        .{ .record = a },
        .resume_yield,
        .{ .checkpoint = .receipt },
    );
    defer restored_finished.deinit();
    var expected: [8]u8 = undefined;
    std.mem.writeInt(u64, &expected, ~@as(u64, 20), .little);
    try std.testing.expectEqualSlices(u8, &expected, finished.outcome.record.record.completed);
    try std.testing.expectEqualSlices(
        u8,
        &expected,
        restored_finished.outcome.record.record.completed,
    );
    try std.testing.expectEqualSlices(
        u8,
        finished.checkpoint.?.bytes(),
        restored_finished.checkpoint.?.bytes(),
    );
}
