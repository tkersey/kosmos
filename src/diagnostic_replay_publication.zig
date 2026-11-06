const std = @import("std");
const data = @import("horos_data");
const kosmos = @import("root.zig");
const projection = @import("semantic/projection.zig");
const artifact = @import("semantic/artifact.zig");
const example = @import("diagnostic_replay_example.zig");
const Observation = @import("semantic/observe.zig").Observation;

pub const Origin = struct {
    allocator: std.mem.Allocator,
    owner: kosmos.Resident,
    publication: kosmos.Publication,
    binding: kosmos.RuntimeCapsule.Binding,
    observed: kosmos.RuntimeObservation,

    pub fn init(a: std.mem.Allocator, prepared: *const kosmos.Prepared, input: []const u8) !Origin {
        var owner = try kosmos.Resident.start(a, prepared, input);
        errdefer close(&owner, a);
        var trace: [512]u8 = undefined;
        var publication = try owner.publish(.{ .record = a }, .none, .{
            .quantum = 100,
            .checkpoint = .receipt,
            .trace_buffer = &trace,
        });
        errdefer publication.deinit();
        try example.require(publication.outcome.record.record == .requested);
        var observed = try owner.runtimeObservation(a);
        errdefer observed.deinit();
        const initial_checkpoint = try owner.checkpoint(a);
        defer a.free(initial_checkpoint);
        try example.require(std.mem.eql(
            u8,
            initial_checkpoint,
            publication.checkpoint.?.bytes(),
        ));
        return .{
            .allocator = a,
            .owner = owner,
            .publication = publication,
            .binding = try owner.runtimeBinding(),
            .observed = observed,
        };
    }

    pub fn deinit(self: *Origin) void {
        if (self.owner.live) {
            self.owner.transferCheckpoint(self.publication.checkpoint.?) catch {
                close(&self.owner, self.allocator);
            };
        }
        self.publication.deinit();
        self.observed.deinit();
    }

    pub fn release(self: *Origin) !void {
        try self.owner.transferCheckpoint(self.publication.checkpoint.?);
    }

    pub fn checkpoint(self: *const Origin) []const u8 {
        return self.publication.checkpoint.?.bytes();
    }

    pub fn unchanged(self: *Origin) !void {
        const bytes = try self.owner.checkpoint(self.allocator);
        defer self.allocator.free(bytes);
        try example.require(std.mem.eql(u8, bytes, self.checkpoint()));
        try example.require(std.meta.eql(self.binding, try self.owner.runtimeBinding()));
        var current = try self.owner.runtimeObservation(self.allocator);
        defer current.deinit();
        try example.require(std.mem.eql(u8, self.observed.observation, current.observation));
        try example.require(std.meta.eql(self.binding, try self.owner.runtimeBinding()));
        const pending = self.publication.checkpoint.?.pendingStateDigest();
        try example.require(pending != null);
    }

    pub fn viewBinding(
        self: *const Origin,
        guest: [32]u8,
        core: [32]u8,
    ) kosmos.RuntimeViews.Binding {
        return .{
            .guest = guest,
            .core = core,
            .realization = self.binding.artifact.digest,
            .checkpoint = artifact.digest(self.checkpoint()),
            .execution = artifact.digest("diagnostic-example/private-owner"),
            .guest_revision = self.binding.guest_revision,
            .realization_revision = self.binding.outer_revision,
            .disclosure = artifact.digest("diagnostic-example/metadata-only"),
        };
    }
};

fn close(owner: *kosmos.Resident, a: std.mem.Allocator) void {
    if (!owner.live) return;
    const bytes = owner.takeCheckpoint(a) catch |err| std.debug.panic("{s}", .{@errorName(err)});
    a.free(bytes);
}

pub const Recording = struct {
    arena: std.heap.ArenaAllocator,
    exchanges: [2]kosmos.RuntimeAnalysis.ReplayExchange,
    terminal: Observation,
    checkpoint: []const u8,
    acquired: u64,
    committed: u64,
    failed_attempts: u64,
    guest_work: u64,

    pub fn deinit(self: *Recording) void {
        self.arena.deinit();
    }
};

pub fn record(a: std.mem.Allocator, origin: *Origin) !Recording {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var result: Recording = .{
        .arena = undefined,
        .exchanges = undefined,
        .terminal = undefined,
        .checkpoint = undefined,
        .acquired = 0,
        .committed = 0,
        .failed_attempts = 0,
        .guest_work = 0,
    };
    var first = try publishReply(a, owned, origin, &origin.publication, &result, 0);
    defer first.deinit();
    var second = try publishReply(a, owned, origin, &first, &result, 1);
    defer second.deinit();
    try example.require(second.outcome.record.record == .completed);
    result.checkpoint = try owned.dupe(u8, second.checkpoint.?.bytes());
    var terminal = try origin.owner.runtimeObservation(a);
    defer terminal.deinit();
    const decoded = try projection.decode(Observation, owned, terminal.observation);
    result.terminal = decoded.value;
    try example.require(result.terminal == .completed);
    try example.require(std.mem.eql(
        u8,
        result.terminal.completed,
        &example.integer(example.answer),
    ));
    try example.require(result.acquired == 2 and result.committed == 2);
    result.arena = arena;
    return result;
}

fn publishReply(
    a: std.mem.Allocator,
    owned: std.mem.Allocator,
    origin: *Origin,
    prior: *const kosmos.Publication,
    recording: *Recording,
    index: usize,
) !kosmos.Publication {
    var decoded_request = try data.invocation.decode(
        data.invocation.Request,
        a,
        prior.outcome.record.record.requested.request,
    );
    defer decoded_request.deinit();
    const request = decoded_request.value;
    const value = example.integer(if (index == 0) 5 else 7);
    recording.acquired += 1;
    const reply = try data.invocation.encodeOwned(data.invocation.Result, a, .{
        .request_identity = request.request_identity,
        .value = &value,
    });
    defer a.free(reply);
    if (index == 0) {
        try rejectedPublication(a, origin, reply, recording);
        try rejectedOutput(a, origin, reply, recording);
    }
    const before = try origin.owner.runtimeBinding();
    var trace: [512]u8 = undefined;
    var published = try origin.owner.publish(.{ .record = a }, .{ .reply = reply }, .{
        .quantum = 100,
        .checkpoint = .receipt,
        .trace_buffer = &trace,
    });
    errdefer published.deinit();
    try verifyPublication(a, origin, &published, before, index);
    recording.exchanges[index] = .{
        .expected_request = .{
            .effect = request.binding.effect,
            .payload = try owned.dupe(u8, request.binding.payload),
        },
        .response = try owned.dupe(u8, &value),
    };
    recording.committed += 1;
    recording.guest_work += published.guest_work;
    try example.require(recording.acquired == recording.committed);
    return published;
}

fn rejectedPublication(
    a: std.mem.Allocator,
    origin: *Origin,
    reply: []const u8,
    recording: *Recording,
) !void {
    const binding = try origin.owner.runtimeBinding();
    var output: [4096]u8 = @splat(0xa5);
    if (origin.owner.publish(.{ .buffer = &output }, .{ .reply = reply }, .{
        .quantum = 100,
        .checkpoint = .receipt,
        .trace_buffer = &.{},
    })) |success| {
        var unexpected = success;
        unexpected.deinit();
        return error.ExpectedPublicationFailure;
    } else |err| {
        if (err != error.TracePublicationBlocked) return err;
    }
    recording.failed_attempts += 1;
    try example.require(recording.committed == 0 and recording.acquired == 1);
    try example.require(std.meta.eql(binding, try origin.owner.runtimeBinding()));
    const checkpoint = try origin.owner.checkpoint(a);
    defer a.free(checkpoint);
    try example.require(std.mem.eql(u8, checkpoint, origin.checkpoint()));
}

fn rejectedOutput(
    a: std.mem.Allocator,
    origin: *Origin,
    reply: []const u8,
    recording: *Recording,
) !void {
    const binding = try origin.owner.runtimeBinding();
    var output: [1]u8 = @splat(0xa5);
    var trace: [512]u8 = @splat(0xa5);
    if (origin.owner.publish(.{ .buffer = &output }, .{ .reply = reply }, .{
        .quantum = 100,
        .checkpoint = .receipt,
        .trace_buffer = &trace,
    })) |success| {
        var unexpected = success;
        unexpected.deinit();
        return error.ExpectedPublicationFailure;
    } else |err| {
        if (err != error.Capacity) return err;
    }
    recording.failed_attempts += 1;
    try example.require(!std.mem.allEqual(u8, &trace, 0xa5));
    try example.require(recording.committed == 0 and recording.acquired == 1);
    try example.require(std.meta.eql(binding, try origin.owner.runtimeBinding()));
    const checkpoint = try origin.owner.checkpoint(a);
    defer a.free(checkpoint);
    try example.require(std.mem.eql(u8, checkpoint, origin.checkpoint()));
}

fn verifyPublication(
    a: std.mem.Allocator,
    origin: *Origin,
    published: *const kosmos.Publication,
    before: kosmos.RuntimeCapsule.Binding,
    index: usize,
) !void {
    const trace = published.trace orelse return error.MissingTrace;
    const receipt = published.checkpoint orelse return error.MissingCheckpoint;
    const current = try origin.owner.runtimeBinding();
    try example.require(current.generation == before.generation + 1);
    try example.require(std.meta.eql(current.artifact.digest, trace.realization));
    try example.require(current.guest_revision == trace.guest_revision);
    const actual = try origin.owner.checkpoint(a);
    defer a.free(actual);
    try example.require(std.mem.eql(u8, actual, receipt.bytes()));
    const control = trace.trace.control orelse return error.MissingTrace;
    const expected: data.process_state.Status = if (index == 0) .parked else .completed;
    try example.require(control.status == expected);
    if (index == 0) {
        var requested = try data.invocation.decode(
            data.invocation.Request,
            a,
            published.outcome.record.record.requested.request,
        );
        defer requested.deinit();
        try example.require(std.meta.eql(
            receipt.pendingStateDigest().?,
            requested.value.binding.pending_state_digest,
        ));
        try example.require(control.effect.? == requested.value.binding.effect);
    } else try example.require(receipt.pendingStateDigest() == null);
}

pub fn rejectReplayReply(a: std.mem.Allocator, live: *Origin, result: []const u8) !void {
    if (live.owner.publish(.{ .record = a }, .{ .reply = result }, .{
        .quantum = 0,
        .checkpoint = .receipt,
    })) |success| {
        var unexpected = success;
        unexpected.deinit();
        return error.ReplayConferredReplyAuthority;
    } else |err| {
        if (err != error.InvalidFamily) return err;
    }
    try live.unchanged();
}
