// Copyright (c) 2026 World contributors. MIT license.
//! One definition of deep reattachment and plain shallow context removal.
const data = @import("horos_data");
const g = data.graph;

pub fn activate(machine: anytype, token: g.Capture, after: g.NodeRef) @TypeOf(machine.*).ExecutionError!void {
    const record = try machine.store.get(token.delimiter);
    if (record != .attachment) return error.InvalidState;
    var attachment = record.attachment;
    attachment.return_to = after;
    attachment.phase = .active;
    try machine.store.replace(token.delimiter, .{ .attachment = attachment });
}

pub fn prepare(machine: anytype, token: g.Capture, after: g.NodeRef) @TypeOf(machine.*).ExecutionError!?g.NodeRef {
    const signature = machine.program.schemas[@intCast(token.schema)].internal.resumption;
    if (signature.mode == .deep) {
        try activate(machine, token, after);
        return token.evidence;
    }
    const original = try machine.store.get(token.delimiter);
    if (original != .attachment) return error.InvalidState;
    const outer = original.attachment.outer;
    // The replacement continuation also owns a stable activation view in the
    // successor. Copy that view before publishing the replacement node.
    try machine.frames.copyFrame(after.id, token.delimiter.id);
    try machine.store.replace(token.delimiter, try machine.store.get(after));
    for (machine.store.nodes.items, machine.store.alive.items, 0..) |stored, alive, id| {
        if (!alive) continue;
        var record = stored;
        const evidence: ?*?g.NodeRef = switch (record) {
            .control => |*v| &v.evidence,
            .continuation => |*v| &v.evidence,
            .handler => |*v| &v.evidence,
            .attachment => |*v| &v.outer,
            .protection => |*v| &v.evidence,
            .one_shot, .multi_template => |*v| &v.evidence,
            else => null,
        };
        // These are lexical context links. Explicit capability values keep
        // their original identities and are never silently redirected.
        if (evidence) |link| if (link.*) |reference| {
            if (reference.id == token.delimiter.id) {
                link.* = outer;
                // Mutate a local record first. Store owns both the old journal
                // entry and replacement slices until publication or rollback.
                try machine.store.replace(.{ .id = @intCast(id) }, record);
            }
        };
    }
    return if (token.evidence != null and token.evidence.?.id == token.delimiter.id)
        outer
    else
        token.evidence;
}
