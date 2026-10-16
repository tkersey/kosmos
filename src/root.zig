// Copyright (c) 2026 World contributors. MIT license.
pub const package_version = "9.0.0";
const current = @import("semantic/session.zig");
pub const Session = current.Session;
pub const Prepared = current.Prepared;
pub const Resident = current.Resident;
pub const Checkpoint = current.resident_types.Checkpoint;
pub const Publication = current.resident_types.Publication;
pub const CapsuleReceipt = current.resident_types.CapsuleReceipt;
pub const RuntimeArtifact = @import("semantic/artifact.zig").Admitted;
pub const RuntimeCapsule = @import("semantic/capsule.zig");
/// Host-side source construction and independent derivation validation. This
/// namespace is not part of the restricted base's execution closure.
pub const RuntimeCompiler = @import("semantic/compiler.zig");
pub const RuntimeViews = @import("semantic/views.zig");
pub const RuntimeInstrumentation = @import("semantic/instrumentation.zig");
pub const invocation = current.invocation;
pub const Workspace = current.Workspace;
pub const AllocationBudget = current.AllocationBudget;
pub const Statistics = @import("interpreter_v2/runtime_types.zig").Statistics;
