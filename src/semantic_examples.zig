//! Runnable hypothetical-analysis example used by native consumers.
const data = @import("horos_data");
const source = @import("horos").source;
const Author = @import("semantic/author.zig").Author;

/// A small actual Horos guest: ask for a number and add it to the input.
pub fn exampleGuest(b: *source.Builder) !source.ast.Module {
    const e = try Author.init(b);
    const effect = try b.effect(.{
        .identity = "analysis/example-number",
        .payload = e.unit,
        .result = e.integer,
    });
    const entry = try b.declare(&.{e.integer}, e.integer, &.{effect}, &.{});
    const answer = try b.variable(e.integer);
    try b.define(entry, try b.bind(answer, try b.term(.{ .perform = .{
        .effect = effect,
        .payload = e.unit_value,
    } }), try b.pure(try e.binary(.integer_add, try e.param(entry, 0), try b.reference(answer)))));
    return b.module(entry, e.unit);
}

pub fn example(b: *source.Builder) !source.ast.Module {
    var guest_builder = source.Builder.init(b.allocator());
    defer guest_builder.deinit();
    var compiled = try source.lower(b.allocator(), try exampleGuest(&guest_builder));
    defer compiled.deinit();
    const image = try b.allocator().alloc(
        u8,
        try data.program_image.encodedLength(compiled.program),
    );
    defer b.allocator().free(image);
    _ = try compiled.encode(b.allocator(), image);
    const guest = try data.program_image.Admitted.decode(b.allocator(), image);
    defer guest.deinit();
    return @import("semantic/analysis.zig").hypotheticalReply(b, guest);
}
