// Copyright (c) 2026 World contributors. MIT license.
const ordinary = @import("ordinary.zig");
pub const package_version = ordinary.package_version;
pub const Session = ordinary.Session;
pub const Prepared = ordinary.Prepared;
pub const Resident = ordinary.Resident;
pub const Checkpoint = ordinary.Checkpoint;
pub const Publication = ordinary.Publication;
pub const RuntimeObservation = ordinary.RuntimeObservation;
pub const CapsuleReceipt = ordinary.CapsuleReceipt;
pub const RuntimeArtifact = ordinary.RuntimeArtifact;
pub const RuntimeCapsule = ordinary.RuntimeCapsule;
/// Host-side source construction and independent derivation validation. This
/// namespace is not part of the restricted base's execution closure.
pub const RuntimeCompiler = if (@hasDecl(@import("recovery_options"), "horos_package"))
    @import("semantic/recovery_compiler.zig")
else
    ordinary.RuntimeCompiler;
pub const RuntimeViews = ordinary.RuntimeViews;
pub const RuntimeAnalysis = ordinary.RuntimeAnalysis;
pub const RuntimeInstrumentation = ordinary.RuntimeInstrumentation;
pub const RuntimeExperiment = ordinary.RuntimeExperiment;
pub const RuntimeTransformation = ordinary.RuntimeTransformation;
pub const invocation = ordinary.invocation;
pub const Workspace = ordinary.Workspace;
pub const AllocationBudget = ordinary.AllocationBudget;
pub const Statistics = ordinary.Statistics;
