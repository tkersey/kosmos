//! Shared private storage checks; current source/evaluator tests live under test/.
test {
    _ = @import("resident.zig");
    _ = @import("arena.zig");
    _ = @import("allocation_budget.zig");
    _ = @import("activation_slots_tests.zig");
    _ = @import("custody_tests.zig");
    _ = @import("store_transaction_tests.zig");
    _ = @import("frame_transaction_tests.zig");
    _ = @import("compact_collection_tests.zig");
    _ = @import("clone.zig");
    _ = @import("economy_tests.zig");
    _ = @import("scalar_batch_tests.zig");
    _ = @import("frame_reuse_tests.zig");
    _ = @import("blob_retention_tests.zig");
}
