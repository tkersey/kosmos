// Copyright (c) 2026 World contributors. MIT license.
pub const package_version = "7.0.0";
const current = @import("interpreter_v2/stable_session.zig");
pub const Session = current.Session;
pub const Prepared = current.Prepared;
pub const Resident = current.Resident;
pub const invocation = current.invocation;
pub const Workspace = current.Workspace;
pub const AllocationBudget = current.AllocationBudget;
pub const Statistics = @import("interpreter_v2/runtime_types.zig").Statistics;
