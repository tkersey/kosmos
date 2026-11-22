//! Qualification root includes the portable implementation and frozen oracle.
test {
    _ = @import("src/semantic_specialization_tests.zig");
    _ = @import("src/semantic_recovery_identity_tests.zig");
}
