//! Exercise the public Kosmos module independently of the low-level Session module.
test {
    _ = @import("native_decode.zig");
    _ = @import("publication.zig");
    _ = @import("control_provenance.zig");
    _ = @import("control_provenance_alias.zig");
    _ = @import("implicit_disposal.zig");
}
