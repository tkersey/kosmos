//! Shared response admission. The caller owns the exact expected binding:
//! low-level Session recomputes it; Resident retains it under exclusive mutation.
const std = @import("std");
const data = @import("horos_data");

pub fn answer(
    session: anytype,
    input: []const u8,
    expected: [32]u8,
) @TypeOf(session.*).ExecutionError!void {
    var response = try data.invocation.decode(data.invocation.Result, session.allocator, input);
    defer response.deinit();
    if (session.statistics) |statistics| statistics.expected_binding_checks +|= 1;
    if (!std.mem.eql(u8, &expected, &response.value.request_identity)) return error.InvalidResult;
    if (session.poisoned or session.status != .parked) return error.InvalidState;
    const pending = (try session.store.get(session.roots.pending.?)).pending;
    const effect = session.program.effects[@intCast(pending.effect)];
    var scratch = std.heap.ArenaAllocator.init(session.allocator);
    defer scratch.deinit();
    const literal: data.program.Literal = .{
        .schema = effect.result,
        .bytes = response.value.value,
    };
    try data.admission.value(
        scratch.allocator(),
        session.program.schemas,
        session.value_facts,
        literal,
    );
    errdefer session.poisoned = true; // Resident restores its entry on error.
    const value = try session.store.literal(session.program.schemas, literal);
    try session.resumeContinuation(pending.continuation, value);
    session.roots.pending = null;
    session.status = .active;
}
