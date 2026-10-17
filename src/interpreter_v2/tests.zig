//! Shared private storage checks; current source/evaluator tests live under test/.
test {
    _ = @import("arena.zig");
    _ = @import("allocation_budget.zig");
    _ = @import("activation_slots_tests.zig");
    _ = @import("custody_tests.zig");
    _ = @import("store_transaction_tests.zig");
    _ = @import("frame_transaction_tests.zig");
    _ = @import("compact_collection_tests.zig");
}
