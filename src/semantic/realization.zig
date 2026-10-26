//! Read only framing for carried recovery programs. Native code locates checked
//! source parameters and runs the authored validators/reifier on the base.
const std = @import("std");
const data = @import("horos_data");
const artifact = @import("artifact.zig");
const projection = @import("projection.zig");
const base = @import("../base/session.zig");
const Values = @import("../interpreter_v2/values.zig").Values;
const g = data.graph;

pub const Inspection = struct {
    committed: usize = 0,
    clone_contexts: usize = 0,
    clone_rebases: usize = 0,
};

pub fn inspect(
    a: std.mem.Allocator,
    session: *base.Session,
    selected: *const artifact.Core,
    guest: *const data.program_image.Admitted,
) !Inspection {
    var result: Inspection = .{};
    var frames = session.frames.entries.iterator();
    while (frames.next()) |entry| {
        const frame = entry.value_ptr.*;
        const reader = try session.frames.slots.reader(frame.view);
        for (selected.content.value.recovery.anchors) |anchor| {
            if (anchor.function != frame.function) continue;
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const temporary = scratch.allocator();
            var values: Values = .{
                .allocator = temporary,
                .schemas = session.program.schemas,
                .store = &session.store,
                .aggregate_storage = .structured,
            };
            const parameters = try temporary.alloc(g.Value, anchor.parameters.len);
            var available = true;
            for (anchor.parameters, 0..) |parameter, i| {
                parameters[i] = reader.at(@intCast(parameter.slot)) catch {
                    available = false;
                    break;
                };
                if (parameters[i].schema != parameter.schema or
                    parameter.ordinal != i) return error.InvalidRecovery;
            }
            if (!available) continue; // map membership does not assert liveness
            try inspectAnchor(
                temporary,
                session,
                selected,
                guest,
                &values,
                anchor,
                parameters,
                &result,
            );
        }
    }
    return result;
}

/// Only the actual parked bridge continuation names a publishable current cut.
/// Other committed anchors certify private progress but are not guest results.
pub fn guestCut(
    a: std.mem.Allocator,
    session: *base.Session,
    selected: *const artifact.Core,
    guest: *const data.program_image.Admitted,
) !data.state_image.Owned {
    if (session.status != .parked) return error.GuestCutUnavailable;
    const pending = (try session.store.get(
        session.roots.pending orelse return error.GuestCutUnavailable,
    )).pending;
    const frame = try session.frames.get(pending.continuation.id);
    const reader = try session.frames.slots.reader(frame.view);
    for (selected.content.value.recovery.anchors) |anchor| {
        if (anchor.function != frame.function or anchor.role != .published_service) continue;
        if (anchor.parameters.len != 1) return error.InvalidRecovery;
        const parameter = anchor.parameters[0];
        const saved = try reader.at(@intCast(parameter.slot));
        if (saved.schema != parameter.schema) return error.InvalidRecovery;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        var values: Values = .{
            .allocator = scratch.allocator(),
            .schemas = session.program.schemas,
            .store = &session.store,
            .aggregate_storage = .structured,
        };
        const machine = try privateField(
            &values,
            saved,
            selected.content.value.recovery.layout.service_machine,
        );
        return reify(a, session, selected, guest, &values, machine);
    }
    return error.MissingRecoveryAnchor;
}

fn reify(
    a: std.mem.Allocator,
    session: *base.Session,
    selected: *const artifact.Core,
    guest: *const data.program_image.Admitted,
    values: *Values,
    machine: g.Value,
) !data.state_image.Owned {
    try bindGuest(
        a,
        values,
        machine,
        guest,
        selected.content.value.recovery.layout.machine_program,
    );
    const input = try arguments(
        a,
        session.program.schemas,
        values,
        &.{machine},
        selected.helpers[0],
    );
    defer a.free(input);
    var helper = try base.Session.start(a, &selected.helper_executables[0], input, .{});
    defer helper.deinit();
    const outcome = try helper.run(null);
    if (outcome != .completed) return error.InvalidRecovery;
    var projected = try projection.decode(
        data.process_state.State,
        a,
        try helper.bytes(&outcome.completed),
    );
    defer projected.deinit();
    var canonical = try data.state_image.canonicalize(a, projected.value);
    errdefer canonical.deinit();
    try data.state_admission.validateAdmitted(a, guest, canonical.state);
    return canonical;
}

fn bindGuest(
    a: std.mem.Allocator,
    values: *Values,
    machine: g.Value,
    guest: *const data.program_image.Admitted,
    program_field: u64,
) !void {
    const program = try privateField(values, machine, program_field);
    const expected = try projection.programBytes(a, guest);
    defer a.free(expected);
    if (!std.mem.eql(
        u8,
        expected,
        try values.bytes(&program),
    )) return error.GuestIdentityMismatch;
}

fn privateField(values: *Values, value: g.Value, index: u64) !g.Value {
    if (value.schema >= values.schemas.len) return error.InvalidRecovery;
    const schema = values.schemas[@intCast(value.schema)];
    if (schema != .product or index >= schema.product.len) return error.InvalidRecovery;
    const fields = try values.split(value);
    if (fields.fields.len != schema.product.len) return error.InvalidRecovery;
    return fields.fields[@intCast(index)];
}

fn arguments(
    a: std.mem.Allocator,
    schemas: []const data.program.Schema,
    values: *Values,
    parameters: []const g.Value,
    helper: *const data.program_image.Admitted,
) ![]u8 {
    const program = helper.program();
    const entry = program.functions[@intCast(program.roots.entry)];
    if (entry.inputs.len != parameters.len) return error.InvalidRecovery;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    for (parameters, entry.inputs) |parameter, slot| {
        const actual = try data.schema.encodeOwned(a, schemas, parameter.schema);
        defer a.free(actual);
        const expected = try data.schema.encodeOwned(
            a,
            program.schemas,
            entry.layout.slots[@intCast(slot)],
        );
        defer a.free(expected);
        if (!std.mem.eql(u8, actual, expected)) return error.InvalidRecovery;
        try bytes.appendSlice(a, try values.bytes(&parameter));
    }
    return bytes.toOwnedSlice(a);
}

fn inspectAnchor(
    temporary: std.mem.Allocator,
    session: *base.Session,
    selected: *const artifact.Core,
    guest: *const data.program_image.Admitted,
    values: *Values,
    anchor: artifact.Anchor,
    parameters: []const g.Value,
    result: *Inspection,
) !void {
    switch (anchor.role) {
        .published_service, .committed_service, .committed_machine => {
            const machine = if (anchor.role == .committed_machine)
                parameters[0]
            else
                try privateField(
                    values,
                    parameters[0],
                    selected.content.value.recovery.layout.service_machine,
                );
            var recovered = try reify(
                temporary,
                session,
                selected,
                guest,
                values,
                machine,
            );
            recovered.deinit();
            result.committed += 1;
        },
        .clone_context, .clone_rebase => {
            const helper_index: usize = if (anchor.role == .clone_context) 2 else 3;
            const layout = selected.content.value.recovery.layout;
            const machine = if (anchor.role == .clone_context)
                try privateField(values, parameters[0], layout.clone_machine)
            else
                parameters[0];
            try bindGuest(temporary, values, machine, guest, layout.machine_program);
            const bytes = try arguments(
                temporary,
                session.program.schemas,
                values,
                parameters,
                selected.helpers[helper_index],
            );
            var validator = try base.Session.start(
                temporary,
                &selected.helper_executables[helper_index],
                bytes,
                .{},
            );
            defer validator.deinit();
            const outcome = try validator.run(null);
            if (outcome != .completed) return error.InvalidRecovery;
            var valid = try projection.decode(
                bool,
                temporary,
                try validator.bytes(&outcome.completed),
            );
            defer valid.deinit();
            if (!valid.value) return error.InvalidRecovery;
            if (helper_index == 2) result.clone_contexts += 1 else result.clone_rebases += 1;
        },
    }
}
