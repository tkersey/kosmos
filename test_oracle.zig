//! Frozen native guest evaluator, compiled only by qualification targets.
const engine = @import("test/oracle/stable_session.zig");
pub const Session = engine.Session;
pub const Prepared = engine.Prepared;
pub const Resident = engine.Resident;
pub const Observation = engine.Observation;
pub const Error = engine.Error;
pub const invocation = engine.invocation;
pub const Workspace = engine.Workspace;
pub const AllocationBudget = engine.AllocationBudget;
pub const Statistics = @import("src/interpreter_v2/runtime_types.zig").Statistics;
test {
    _ = engine.resident_types;
    _ = @import("test/oracle/clone.zig");
    _ = @import("test/oracle/economy_tests.zig");
    _ = @import("test/oracle/scalar_batch_tests.zig");
    _ = @import("test/oracle/frame_reuse_tests.zig");
    _ = @import("test/oracle/blob_retention_tests.zig");
}
