// Copyright (c) 2026 World contributors. MIT license.
//! Error and observation vocabulary shared by the current execution machinery.
const data = @import("horos_data");

pub const Error = data.program_image.Error || data.state_admission.Error ||
    data.invocation.Error || data.scalar.Error || error{UnsupportedTransition};

/// Work counters are observations, never serialized state or execution limits.
pub const Statistics = struct {
    /// Counts include failed attempts and are never restored by rollback.
    state_projections: u64 = 0,
    pending_bindings: u64 = 0,
    expected_binding_checks: u64 = 0,
    reused_expected_bindings: u64 = 0,
    transitions: u64 = 0,
    base_transitions: u64 = 0,
    dispatches: u64 = 0,
    batched_scalar_operations: u64 = 0,
    tail_frame_reuses: u64 = 0,
    tail_frame_reuse_fallbacks: u64 = 0,
    stack_argument_calls: u64 = 0,
    heap_argument_calls: u64 = 0,
    early_blob_collections: u64 = 0,
    direct_clauses: u64 = 0,
    one_shot_captures: u64 = 0,
    multi_templates: u64 = 0,
    branch_activations: u64 = 0,
    storage: @import("store.zig").Statistics = .{},
    snapshot: data.graph_order.Statistics = .{},
};
