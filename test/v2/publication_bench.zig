const std = @import("std");
const horos = @import("horos");
const kosmos = @import("kosmos");
const data = horos.data;

fn program(a: std.mem.Allocator, external: bool) ![]u8 {
    if (!external) {
        const bytes = try a.alloc(u8, 52);
        _ = try std.fmt.hexToBytes(
            bytes,
            "41424c5f4250493303000000200000000000000001000001020a000000010000" ++
                "0100010000020000070100000000000000000000",
        );
        return bytes;
    }
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const bytes = try b.schema(.bytes);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{
        .identity = "publication/bench",
        .payload = unit,
        .result = unit,
    });
    const entry = try b.declare(&.{bytes}, bytes, &.{effect}, &.{});
    try b.define(entry, try b.bind(try b.variable(unit), try b.term(.{ .perform = .{
        .effect = effect,
        .payload = try b.constant(void, {}),
    } }), try b.pure(try b.reference(b.parameter(entry, 0)))));
    var compiled = try horos.program.compile(a, b.module(entry, unit));
    defer compiled.deinit();
    const encoded = try a.alloc(u8, try data.program_image.encodedLength(compiled.program));
    errdefer a.free(encoded);
    _ = try compiled.encode(a, encoded);
    return encoded;
}

fn budget(a: std.mem.Allocator) kosmos.AllocationBudget {
    return .{ .parent = a, .limit = std.math.maxInt(usize) };
}

fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

const Measurements = struct {
    external: bool,
    payload_bytes: usize,
    sample: usize,
    image_sha256: [64]u8,
    checkpoint_sha256: [64]u8 = undefined,
    prepare_ns: i96 = 0,
    prepare_live: usize = 0,
    prepare_peak: usize = 0,
    start_ns: i96 = 0,
    start_live: usize = 0,
    start_peak: usize = 0,
    publish_ns: i96 = 0,
    publish_peak: usize = 0,
    publish_output_peak: usize = 0,
    publication_output_live: usize = 0,
    resident_live_after_publication: usize = 0,
    checkpoint_bytes: usize = 0,
    receipt_retained_bytes: usize = 0,
    snapshot_ns: i96 = 0,
    snapshot_peak: usize = 0,
    snapshot_output_peak: usize = 0,
    transfer_ns: i96 = 0,
    publication_projections: u64 = 0,
    transfer_projections: u64 = 0,
    restore_ns: i96 = 0,
    restore_live: usize = 0,
    restore_peak: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    for ([_]bool{ false, true }) |external| {
        const image = try program(init.gpa, external);
        defer init.gpa.free(image);
        var image_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(image, &image_hash, .{});
        for ([_]usize{ 64, 1 << 20, 65 << 20 }) |size| {
            var measure: data.wire.Writer = .{};
            try measure.natural(size);
            const argument = try init.gpa.alloc(u8, measure.position + size);
            defer init.gpa.free(argument);
            var writer: data.wire.Writer = .{ .output = argument };
            try writer.natural(size);
            @memset(argument[writer.position..], 0x39);
            for (0..@as(usize, if (size > 1 << 20) 5 else 11)) |sample| {
                var measurements: Measurements = .{
                    .external = external,
                    .payload_bytes = size,
                    .sample = sample,
                    .image_sha256 = std.fmt.bytesToHex(image_hash, .lower),
                };
                try measureSample(init.gpa, init.io, image, argument, &measurements);
                try std.json.Stringify.value(measurements, .{}, &output.interface);
                try output.interface.writeByte('\n');
            }
            try output.interface.flush();
        }
    }
}

fn measureSample(
    a: std.mem.Allocator,
    io: std.Io,
    image: []const u8,
    argument: []const u8,
    result: *Measurements,
) !void {
    var prep = budget(a);
    const prepare_start = now(io);
    var prepared = try kosmos.Prepared.init(prep.allocator(), image);
    result.prepare_ns = prepare_start.durationTo(now(io)).nanoseconds;
    var resident_meter = budget(a);
    var output_meter = budget(a);
    const start = now(io);
    var resident = try kosmos.Resident.start(resident_meter.allocator(), &prepared, argument);
    result.start_ns = start.durationTo(now(io)).nanoseconds;
    result.start_peak = resident_meter.peak;
    result.start_live = resident_meter.live;
    var statistics: kosmos.Statistics = .{};
    try resident.setStatistics(&statistics);
    resident_meter.resetObservation();
    const publish_start = now(io);
    var publication = try resident.publish(.{
        .encoded = output_meter.allocator(),
    }, .none, .{ .checkpoint = .receipt });
    result.publish_ns = publish_start.durationTo(now(io)).nanoseconds;
    result.publish_peak = resident_meter.peak;
    result.publish_output_peak = output_meter.peak;
    result.publication_projections = statistics.state_projections;
    if (result.publication_projections != 1) return error.DuplicateProjection;
    const receipt = publication.takeCheckpoint().?;
    publication.deinit();
    result.publication_output_live = output_meter.live;
    result.resident_live_after_publication = resident_meter.live;
    result.checkpoint_bytes = receipt.bytes().len;
    var checkpoint_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(receipt.bytes(), &checkpoint_hash, .{});
    result.checkpoint_sha256 = std.fmt.bytesToHex(checkpoint_hash, .lower);
    try measureSnapshot(io, &resident, &resident_meter, &output_meter, receipt.bytes(), result);
    const projections_before_transfer = statistics.state_projections;
    const transfer_start = now(io);
    try resident.transferCheckpoint(receipt);
    result.transfer_ns = transfer_start.durationTo(now(io)).nanoseconds;
    if (statistics.state_projections != projections_before_transfer) return error.TransferProjected;
    result.receipt_retained_bytes = resident_meter.live;
    try measureRestore(a, io, &prepared, receipt.bytes(), argument, result);
    receipt.deinit();
    result.prepare_live = prep.live;
    result.prepare_peak = prep.peak;
    result.transfer_projections = statistics.state_projections - projections_before_transfer;
    prepared.deinit();
    if (prep.live != 0 or resident_meter.live != 0 or output_meter.live != 0)
        return error.LeakedOwner;
}

fn measureSnapshot(
    io: std.Io,
    resident: *kosmos.Resident,
    resident_meter: *kosmos.AllocationBudget,
    output_meter: *kosmos.AllocationBudget,
    checkpoint: []const u8,
    result: *Measurements,
) !void {
    resident_meter.resetObservation();
    output_meter.resetObservation();
    const start = now(io);
    const snapshot = try resident.checkpoint(output_meter.allocator());
    result.snapshot_ns = start.durationTo(now(io)).nanoseconds;
    result.snapshot_peak = resident_meter.peak;
    result.snapshot_output_peak = output_meter.peak;
    if (!std.mem.eql(u8, snapshot, checkpoint)) return error.CheckpointChanged;
    output_meter.allocator().free(snapshot);
}

fn measureRestore(
    a: std.mem.Allocator,
    io: std.Io,
    prepared: *const kosmos.Prepared,
    checkpoint: []const u8,
    argument: []const u8,
    result: *Measurements,
) !void {
    var restore_meter = budget(a);
    const restore_start = now(io);
    var restored = try kosmos.Resident.restore(restore_meter.allocator(), prepared, checkpoint);
    result.restore_ns = restore_start.durationTo(now(io)).nanoseconds;
    result.restore_peak = restore_meter.peak;
    result.restore_live = restore_meter.live;
    var terminal = if (result.external) blk: {
        var pending = try restored.drive(a, .none, .{ .quantum = 0 });
        defer pending.deinit();
        var request = try data.invocation.decode(
            data.invocation.Request,
            a,
            pending.record.requested.request,
        );
        defer request.deinit();
        const reply = try data.invocation.encodeOwned(
            data.invocation.Result,
            a,
            .{ .request_identity = request.value.request_identity, .value = &.{} },
        );
        defer a.free(reply);
        break :blk try restored.drive(a, .{ .reply = reply }, .{});
    } else try restored.drive(a, .resume_yield, .{});
    defer terminal.deinit();
    if (terminal.record != .completed or !std.mem.eql(u8, terminal.record.completed, argument))
        return error.ResultChanged;
    try restored.close();
    if (restore_meter.live != 0) return error.LeakedOwner;
}
