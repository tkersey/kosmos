const std = @import("std");
const legacy = @import("compiler.zig");
const backend = @import("recovery_backend.zig");
const artifact = @import("artifact.zig");

pub const recovery_policy = backend.policy;
pub const recovery_limits = backend.limits;
pub const recoveryContext = backend.context;
pub const RecoveryEvidence = backend.Evidence;
pub const RecoveryDerivation = backend.Derivation;

pub const Options = struct {
    horos_package: []const u8,
    guest: @FieldType(legacy.Options, "guest") = null,
    hooks: @FieldType(legacy.Options, "hooks") = .{},
    policy: @FieldType(legacy.Options, "policy") = (legacy.Options{ .horos_package = "" }).policy,
    scalar_field_reuse: bool = false,
};

pub fn compile(a: std.mem.Allocator, options: Options) ![]u8 {
    const original: legacy.Options = .{
        .horos_package = options.horos_package,
        .guest = options.guest,
        .hooks = options.hooks,
        .policy = options.policy,
    };
    if (options.scalar_field_reuse) return backend.compile(a, original);
    return legacy.compile(a, original);
}

pub fn validate(a: std.mem.Allocator, admitted: *const artifact.Admitted) !void {
    return validateWithPolicy(a, admitted, .{});
}

pub fn validateWithPolicy(
    a: std.mem.Allocator,
    admitted: *const artifact.Admitted,
    policy: ValidationPolicy,
) !void {
    if (std.mem.eql(u8, admitted.content.value.manifest.compiler.policy, recovery_policy))
        return backend.validate(a, admitted);
    return legacy.validateWithPolicy(a, admitted, policy);
}

pub fn validateAgainst(
    a: std.mem.Allocator,
    candidate: *const artifact.Admitted,
    ancestor: *const artifact.Admitted,
) !void {
    if (!std.mem.eql(u8, candidate.content.value.manifest.compiler.policy, recovery_policy))
        return legacy.validateAgainst(a, candidate, ancestor);
    if (!std.mem.eql(u8, &candidate.identity, &ancestor.identity)) return error.InvalidAncestor;
    return backend.validate(a, candidate);
}

pub const checker_identity = legacy.checker_identity;
pub const Proposal = legacy.Proposal;
pub const RecordProposal = legacy.RecordProposal;
pub const ProposedInterfaces = legacy.ProposedInterfaces;
pub const DeriveOptions = legacy.DeriveOptions;
pub const ValidationPolicy = legacy.ValidationPolicy;
pub const derive = legacy.derive;
pub const deriveRecord = legacy.deriveRecord;
pub const approvedRootIdentity = legacy.approvedRootIdentity;
pub const Derivation = legacy.Derivation;
pub const Evidence = legacy.Evidence;
pub const SourceDefinition = legacy.SourceDefinition;
pub const SourceModule = legacy.SourceModule;
pub const SourceReferences = legacy.SourceReferences;
pub const OwnedSourceReferences = legacy.OwnedSourceReferences;
pub const sourceReferences = legacy.sourceReferences;
pub const SourceHelper = legacy.SourceHelper;
pub const PureEntry = legacy.PureEntry;
pub const SourceEntries = legacy.SourceEntries;
pub const SourceBundle = legacy.SourceBundle;
pub const ExportedSource = legacy.ExportedSource;
pub const exportSource = legacy.exportSource;
pub const exportBuiltinSource = legacy.exportBuiltinSource;
pub const sourceModule = legacy.sourceModule;
pub const context = legacy.context;
pub const contextWithHooks = legacy.contextWithHooks;
pub const SourceRole = legacy.SourceRole;
pub const anchorsForRoles = legacy.anchorsForRoles;
