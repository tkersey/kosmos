//! Exact authored source closure, ordered and length framed. The compiler package
//! is bound separately by the authenticated build dependency.
const std = @import("std");
pub fn digest() [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("kosmos.semantic-source/1");
    inline for (.{
        .{ "aggregate.zig", @embedFile("aggregate.zig") },
        .{ "artifact.zig", @embedFile("artifact.zig") },
        .{ "author.zig", @embedFile("author.zig") },
        .{ "blob_instructions.zig", @embedFile("blob_instructions.zig") },
        .{ "captures.zig", @embedFile("captures.zig") },
        .{ "cleanup.zig", @embedFile("cleanup.zig") },
        .{ "clone.zig", @embedFile("clone.zig") },
        .{ "clone_validation.zig", @embedFile("clone_validation.zig") },
        .{ "codec.zig", @embedFile("codec.zig") },
        .{ "compiler.zig", @embedFile("compiler.zig") },
        .{ "construction.zig", @embedFile("construction.zig") },
        .{ "collect.zig", @embedFile("collect.zig") },
        .{ "collection_instructions.zig", @embedFile("collection_instructions.zig") },
        .{ "collections.zig", @embedFile("collections.zig") },
        .{ "control.zig", @embedFile("control.zig") },
        .{ "edges.zig", @embedFile("edges.zig") },
        .{ "frames.zig", @embedFile("frames.zig") },
        .{ "graph.zig", @embedFile("graph.zig") },
        .{ "handlers.zig", @embedFile("handlers.zig") },
        .{ "instructions.zig", @embedFile("instructions.zig") },
        .{ "instrumentation.zig", @embedFile("instrumentation.zig") },
        .{ "lifecycle.zig", @embedFile("lifecycle.zig") },
        .{ "machine.zig", @embedFile("machine.zig") },
        .{ "map.zig", @embedFile("map.zig") },
        .{ "memory_instructions.zig", @embedFile("memory_instructions.zig") },
        .{ "observe.zig", @embedFile("observe.zig") },
        .{ "projection.zig", @embedFile("projection.zig") },
        .{ "projection_cache.zig", @embedFile("projection_cache.zig") },
        .{ "references.zig", @embedFile("references.zig") },
        .{ "record_equal.zig", @embedFile("record_equal.zig") },
        .{ "recovery.zig", @embedFile("recovery.zig") },
        .{ "scalar.zig", @embedFile("scalar.zig") },
        .{ "service.zig", @embedFile("service.zig") },
        .{ "sets.zig", @embedFile("sets.zig") },
        .{ "staged.zig", @embedFile("staged.zig") },
        .{ "source_identity.zig", @embedFile("source_identity.zig") },
        .{ "step.zig", @embedFile("step.zig") },
        .{ "table.zig", @embedFile("table.zig") },
        .{ "unwind.zig", @embedFile("unwind.zig") },
        .{ "values.zig", @embedFile("values.zig") },
        .{ "../semantic_artifact.zig", @embedFile("../semantic_artifact.zig") },
        .{ "../base/profile.zig", @embedFile("../base/profile.zig") },
    }) |input| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, input[0].len, .little);
        hash.update(&length);
        hash.update(input[0]);
        std.mem.writeInt(u64, &length, input[1].len, .little);
        hash.update(&length);
        hash.update(input[1]);
    }
    return hash.finalResult();
}
