//! Portable semantics and restricted-base checks share the native check graph.
test {
    _ = @import("base/profile.zig");
    _ = @import("base/value_tests.zig");
    _ = @import("base/session_tests.zig");
    _ = @import("semantic/projection.zig");
    _ = @import("semantic/view_tests.zig");
    _ = @import("semantic/table_tests.zig");
    _ = @import("semantic/state_storage_tests.zig");
    _ = @import("semantic/scalar_tests.zig");
    _ = @import("semantic/map_tests.zig");
    _ = @import("semantic/frame_tests.zig");
    _ = @import("semantic/step_tests.zig");
    _ = @import("semantic/codec_tests.zig");
    _ = @import("semantic/collection_tests.zig");
    _ = @import("semantic/value_instruction_tests.zig");
    _ = @import("semantic/reference_tests.zig");
    _ = @import("semantic/clone_validation_tests.zig");
    _ = @import("semantic/handler_tests.zig");
    _ = @import("semantic/cleanup_tests.zig");
    _ = @import("semantic/lifecycle_tests.zig");
    _ = @import("semantic/collect_tests.zig");
    _ = @import("semantic/service_tests.zig");
}
