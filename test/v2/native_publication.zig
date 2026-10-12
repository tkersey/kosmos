//! Exercise the public Kosmos module independently of the low-level Session module.
test {
    _ = @import("native_decode.zig");
    _ = @import("publication.zig");
}
