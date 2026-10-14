//! Optional measurements using the ordinary public owner and allocator policy.
//! AllocationBudget counts live requested bytes, with no resize/remap; these
//! measurements exclude allocator metadata and RSS. No timing threshold is used.
const std = @import("std");
const horos = @import("horos");
const kosmos = @import("kosmos");
const data = horos.data;

fn program(a: std.mem.Allocator, external: bool) ![]u8 {
    if (!external) {
        const bytes = try a.alloc(u8, 52);
        _ = try std.fmt.hexToBytes(bytes, "41424c5f4250493303000000200000000000000001000001020a0000000100000100010000020000070100000000000000000000");
        return bytes;
    }
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const bytes = try b.schema(.bytes);
    const unit = try b.scalar(void);
    const effect = try b.effect(.{ .identity = "publication/bench", .payload = unit, .result = unit });
    const entry = try b.declare(&.{bytes}, bytes, &.{effect}, &.{});
    try b.define(entry, try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = effect, .payload = try b.constant(void, {}) } }), try b.pure(try b.reference(b.parameter(entry, 0)))));
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
                var prep = budget(init.gpa);
                const prepare_start = now(init.io);
                var prepared = try kosmos.Prepared.init(prep.allocator(), image);
                const prepare_ns = prepare_start.durationTo(now(init.io)).nanoseconds;
                var resident_meter = budget(init.gpa);
                var output_meter = budget(init.gpa);
                const start = now(init.io);
                var resident = try kosmos.Resident.start(resident_meter.allocator(), &prepared, argument);
                const start_ns = start.durationTo(now(init.io)).nanoseconds;
                const start_peak = resident_meter.peak;
                const start_live = resident_meter.live;
                var statistics: kosmos.Statistics = .{};
                try resident.setStatistics(&statistics);
                resident_meter.resetObservation();
                const publish_start = now(init.io);
                var publication = try resident.publish(.{ .encoded = output_meter.allocator() }, .none, .{ .checkpoint = .receipt });
                const publish_ns = publish_start.durationTo(now(init.io)).nanoseconds;
                const publish_peak = resident_meter.peak;
                const publish_output_peak = output_meter.peak;
                const projections = statistics.state_projections;
                if (projections != 1) return error.DuplicateProjection;
                const receipt = publication.takeCheckpoint().?;
                publication.deinit();
                const publication_output_live = output_meter.live;
                const resident_live_after_publication = resident_meter.live;
                const checkpoint_bytes = receipt.bytes().len;
                var checkpoint_hash: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(receipt.bytes(), &checkpoint_hash, .{});

                // The fallback snapshot observes this exact state and must emit
                // the exact same bytes. Its cost is outside publication timing.
                resident_meter.resetObservation();
                output_meter.resetObservation();
                const snapshot_start = now(init.io);
                const snapshot = try resident.checkpoint(output_meter.allocator());
                const snapshot_ns = snapshot_start.durationTo(now(init.io)).nanoseconds;
                const snapshot_peak = resident_meter.peak;
                const snapshot_output_peak = output_meter.peak;
                if (!std.mem.eql(u8, snapshot, receipt.bytes())) return error.CheckpointChanged;
                output_meter.allocator().free(snapshot);
                const projections_before_transfer = statistics.state_projections;
                const transfer_start = now(init.io);
                try resident.transferCheckpoint(receipt);
                const transfer_ns = transfer_start.durationTo(now(init.io)).nanoseconds;
                if (statistics.state_projections != projections_before_transfer) return error.TransferProjected;
                // Receipts use the resident allocator, not the encoded-outcome
                // allocator. After retirement only the receipt and its issuer
                // identity remain in this allocation domain.
                const receipt_retained_bytes = resident_meter.live;

                var restore_meter = budget(init.gpa);
                const restore_start = now(init.io);
                var restored = try kosmos.Resident.restore(restore_meter.allocator(), &prepared, receipt.bytes());
                const restore_ns = restore_start.durationTo(now(init.io)).nanoseconds;
                const restore_peak = restore_meter.peak;
                const restore_live = restore_meter.live;
                // Successful restore must still have the prescribed result.
                var terminal = if (external) blk: {
                    var pending = try restored.drive(init.gpa, .none, .{ .quantum = 0 });
                    defer pending.deinit();
                    var request = try data.invocation.decode(data.invocation.Request, init.gpa, pending.record.requested.request);
                    defer request.deinit();
                    const reply = try data.invocation.encodeOwned(data.invocation.Result, init.gpa, .{ .request_identity = request.value.request_identity, .value = &.{} });
                    defer init.gpa.free(reply);
                    break :blk try restored.drive(init.gpa, .{ .reply = reply }, .{});
                } else try restored.drive(init.gpa, .resume_yield, .{});
                defer terminal.deinit();
                if (terminal.record != .completed or !std.mem.eql(u8, terminal.record.completed, argument)) return error.ResultChanged;
                try restored.close();
                receipt.deinit();
                try std.json.Stringify.value(.{
                    .external = external,
                    .payload_bytes = size,
                    .sample = sample,
                    .image_sha256 = std.fmt.bytesToHex(image_hash, .lower),
                    .checkpoint_sha256 = std.fmt.bytesToHex(checkpoint_hash, .lower),
                    .prepare_ns = prepare_ns,
                    .prepare_live = prep.live,
                    .prepare_peak = prep.peak,
                    .start_ns = start_ns,
                    .start_live = start_live,
                    .start_peak = start_peak,
                    .publish_ns = publish_ns,
                    .publish_peak = publish_peak,
                    .publish_output_peak = publish_output_peak,
                    .publication_output_live = publication_output_live,
                    .resident_live_after_publication = resident_live_after_publication,
                    .checkpoint_bytes = checkpoint_bytes,
                    .receipt_retained_bytes = receipt_retained_bytes,
                    .snapshot_ns = snapshot_ns,
                    .snapshot_peak = snapshot_peak,
                    .snapshot_output_peak = snapshot_output_peak,
                    .transfer_ns = transfer_ns,
                    .publication_projections = projections,
                    .transfer_projections = statistics.state_projections - projections_before_transfer,
                    .restore_ns = restore_ns,
                    .restore_live = restore_live,
                    .restore_peak = restore_peak,
                }, .{}, &output.interface);
                try output.interface.writeByte('\n');
                prepared.deinit();
                if (prep.live != 0 or resident_meter.live != 0 or output_meter.live != 0 or restore_meter.live != 0) return error.LeakedOwner;
            }
            try output.interface.flush();
        }
    }
}
