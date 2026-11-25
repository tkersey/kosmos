// Copyright (c) 2026 World contributors. MIT license.
const std = @import("std");
const data = @import("horos_data");
const protocol = data.invocation;
const core = @import("../semantic/session.zig");
const invocation = @import("../interpreter_v2/invocation.zig");

pub const Step = struct {
    control: protocol.Control,
    quantum: ?u64,
};

pub const Segment = struct {
    start: []const u8,
    steps: []const Step,
    end: []const u8,
    guest_work: ?u64 = null,
};

pub const Certificate = struct {
    start_digest: [32]u8,
    end_digest: [32]u8,
    guest_work: u64,
};

pub const Error = invocation.Error || error{CertificationMismatch};

pub fn replay(
    allocator: std.mem.Allocator,
    prepared: *const core.Prepared,
    segment: Segment,
) Error!Certificate {
    var session = try core.Session.restore(allocator, prepared, segment.start);
    defer session.deinit();
    for (segment.steps) |step| {
        if (session.isTerminal()) return error.CertificationMismatch;
        _ = invocation.advance(&session, step.control, step.quantum) catch |err| switch (err) {
            error.OutOfMemory, error.Capacity => return err,
            else => return error.CertificationMismatch,
        };
    }
    const end = try session.checkpoint(allocator);
    defer allocator.free(end);
    if (!std.mem.eql(u8, end, segment.end)) return error.CertificationMismatch;
    if (segment.guest_work) |work| if (work != session.transitions)
        return error.CertificationMismatch;
    return .{
        .start_digest = digest(segment.start),
        .end_digest = digest(segment.end),
        .guest_work = session.transitions,
    };
}

pub fn digest(bytes: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}
