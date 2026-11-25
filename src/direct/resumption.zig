// Copyright (c) 2026 World contributors. MIT license.
const data = @import("horos_data");
const g = data.graph;
const Session = @import("session.zig").Session;
const Error = @import("session.zig").Error;

pub fn activate(session: *Session, token: g.Capture, after: g.NodeRef) Error!void {
    const record = try session.store.get(token.delimiter);
    if (record != .attachment) return error.InvalidState;
    var attachment = record.attachment;
    attachment.return_to = after;
    attachment.phase = .active;
    try session.store.replace(token.delimiter, .{ .attachment = attachment });
}

pub fn prepare(session: *Session, token: g.Capture, after: g.NodeRef) Error!?g.NodeRef {
    const signature = session.program.schemas[@intCast(token.schema)].internal.resumption;
    if (signature.mode == .deep) {
        try activate(session, token, after);
        return token.evidence;
    }
    const original = try session.store.get(token.delimiter);
    if (original != .attachment) return error.InvalidState;
    const outer = original.attachment.outer;
    try session.frames.copyFrame(after.id, token.delimiter.id);
    try session.store.replace(token.delimiter, try session.store.get(after));
    for (session.store.nodes.items, session.store.alive.items, 0..) |stored, alive, id| {
        if (!alive) continue;
        var record = stored;
        const evidence: ?*?g.NodeRef = switch (record) {
            .control => |*value| &value.evidence,
            .continuation => |*value| &value.evidence,
            .handler => |*value| &value.evidence,
            .attachment => |*value| &value.outer,
            .protection => |*value| &value.evidence,
            .one_shot, .multi_template => |*value| &value.evidence,
            else => null,
        };
        if (evidence) |link| if (link.*) |reference| {
            if (reference.id == token.delimiter.id) {
                link.* = outer;
                try session.store.replace(.{ .id = @intCast(id) }, record);
            }
        };
    }
    return if (token.evidence != null and token.evidence.?.id == token.delimiter.id)
        outer
    else
        token.evidence;
}
