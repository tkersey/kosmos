const std = @import("std");
const Profile = struct {
    zig: []const u8,
    target: []const u8,
    hostMode: []const u8,
    kernelMode: []const u8,
    wasmBackend: enum { llvm },
    wasmLinker: enum { lld },
    cpu: []const u8,
    features: []const []const u8,
    stackBytes: u64,
    maximumMemoryBytes: u64,
    defaults: struct { input: usize, working: usize, output: usize },
};

pub fn build(b: *std.Build) void {
    comptime {
        if (!std.mem.eql(u8, @import("builtin").zig_version_string, "0.17.0"))
            @compileError("Zig 0.17.0 is required");
    }
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = std.json.parseFromSliceLeaky(Profile, b.allocator, @embedFile("build-profile.json"), .{}) catch @panic("invalid runtime profile");
    const package = @import("build.zig.zon");
    const kernel_mode = std.meta.stringToEnum(std.lang.Optimize, profile.kernelMode) orelse @panic("invalid kernel mode");
    const supplied_source = b.option(std.Build.LazyPath, "horos-source", "Override the pinned Horos source") orelse pinned: {
        const dependency = b.lazyDependency("horos", .{
            .target = target,
            .optimize = optimize,
            .@"data-only" = true,
        }) orelse return;
        break :pinned dependency.path("");
    };
    if (supplied_source == .cwd_relative and !std.Io.Dir.path.isAbsolute(supplied_source.cwd_relative))
        @panic("Horos source path must be absolute");
    // Fetch captures the selected package without executing its build code.
    // Every compiler/emitter consumes the authenticated cache snapshot, never
    // the caller's mutable source directory after verification.
    const admission = b.addRunFile(.zig_exe);
    admission.setCwd(b.graph.path(.global_cache, ""));
    admission.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", ".");
    admission.addArg("fetch");
    admission.addDirectoryArg2(supplied_source, .{ .make_absolute = true });
    admission.expectStdOutEqual(package.dependencies.horos.hash ++ "\n");
    admission.has_side_effects = true;
    const snapshot = b.addSystemCommand(&.{ "tar", "-xzf" });
    snapshot.removeEnvironmentVariable("TAR_OPTIONS");
    snapshot.addFileArg2(b.graph.path(.global_cache, "p/" ++ package.dependencies.horos.hash ++ ".tar.gz"), .{ .make_absolute = true });
    snapshot.addArgs(&.{ "--strip-components=1", "--no-same-owner", "-C" });
    const source = snapshot.addOutputDirectoryArg2("horos", .{});
    snapshot.step.dependOn(&admission.step);
    const data = b.createModule(.{
        .root_source_file = source.path(b, "src/data/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const host_data = if (target.query.isNative()) data else b.createModule(.{
        .root_source_file = source.path(b, "src/data/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const public_kosmos = b.addModule("kosmos", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = data }},
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/interpreter_v2/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = host_data }},
    }) });
    const run_native_tests = b.addRunArtifact(tests);
    b.step("check-storage", "Check current private storage and allocation contracts")
        .dependOn(&run_native_tests.step);
    const activation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/interpreter_v2/activation_slots_tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "horos_data", .module = host_data }},
    }) });
    b.step("check-activation-storage", "Check stable activation storage and failure atomicity")
        .dependOn(&b.addRunArtifact(activation_tests).step);
    const host_mode = std.meta.stringToEnum(std.lang.Optimize, profile.hostMode) orelse @panic("invalid host mode");
    const source_data = if (host_mode == optimize) host_data else b.createModule(.{ .root_source_file = source.path(b, "src/data/root.zig"), .target = b.graph.host, .optimize = host_mode });
    const horos = b.createModule(.{ .root_source_file = source.path(b, "src/root.zig"), .target = b.graph.host, .optimize = host_mode, .imports = &.{.{ .name = "horos_data", .module = source_data }} });
    public_kosmos.addImport("horos", if (target.query.isNative() and host_mode == optimize) horos else b.createModule(.{ .root_source_file = source.path(b, "src/root.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "horos_data", .module = data }} }));
    const artifact_options = b.addOptions();
    artifact_options.addOption([]const u8, "horos_package", package.dependencies.horos.hash);
    const artifact_emitter = b.addExecutable(.{ .name = "kosmos-semantic-artifact", .root_module = b.createModule(.{
        .root_source_file = b.path("src/semantic_artifact.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "horos_data", .module = source_data }, .{ .name = "horos", .module = horos } },
    }) });
    artifact_emitter.root_module.addOptions("artifact_options", artifact_options);
    const emit_artifact = b.addRunArtifact(artifact_emitter);
    const semantic_artifact = emit_artifact.captureStdOut(.{});
    const runtime_files = b.addWriteFiles();
    _ = runtime_files.addCopyFile(semantic_artifact, "semantic-core.kar");
    const runtime_source = runtime_files.add("runtime.zig", "pub const bytes = @embedFile(\"semantic-core.kar\");\n");
    const packaged_runtime = b.createModule(.{
        .root_source_file = runtime_source,
        .target = b.graph.host,
        .optimize = host_mode,
    });
    public_kosmos.addImport("packaged_runtime", if (target.query.isNative()) packaged_runtime else b.createModule(.{ .root_source_file = runtime_source, .target = target, .optimize = optimize }));
    b.step("semantic-artifact", "Compile and admit the reproducible portable evaluator bundle")
        .dependOn(&b.addInstallFile(semantic_artifact, "semantic-core.kar").step);
    const host_kosmos = if (target.query.isNative() and host_mode == optimize) public_kosmos else b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = b.graph.host, .optimize = host_mode, .imports = &.{.{ .name = "horos_data", .module = source_data }} });
    if (host_kosmos != public_kosmos) {
        host_kosmos.addImport("packaged_runtime", packaged_runtime);
        host_kosmos.addImport("horos", horos);
    }
    const publication_bench = b.addExecutable(.{ .name = "publication-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/publication_bench.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "kosmos", .module = host_kosmos }, .{ .name = "horos", .module = horos } },
    }) });
    const run_publication_bench = b.addRunArtifact(publication_bench);
    run_publication_bench.has_side_effects = true;
    b.step("bench-publication", "Measure native preparation, publication, receipt custody and restore (JSONL)")
        .dependOn(&b.addInstallFile(run_publication_bench.captureStdOut(.{}), "publication.jsonl").step);
    const economy_bench = b.addExecutable(.{ .name = "semantic-economy", .root_module = b.createModule(.{
        .root_source_file = b.path("bench_semantics.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "horos_data", .module = source_data }, .{ .name = "horos", .module = horos }, .{ .name = "packaged_runtime", .module = packaged_runtime } },
    }) });
    const run_economy_bench = b.addRunArtifact(economy_bench);
    if (b.option([]const u8, "economy-workload", "Select one semantic economy workload")) |name| run_economy_bench.addArg(name);
    run_economy_bench.has_side_effects = true;
    b.step("bench-semantics", "Measure matched native, bootstrap, generic and specialized realizations (JSONL)")
        .dependOn(&run_economy_bench.step);
    const stable_runtime = b.createModule(.{ .root_source_file = b.path("test_oracle.zig"), .target = b.graph.host, .optimize = host_mode, .imports = &.{.{ .name = "horos_data", .module = source_data }} });
    const oracle_tests = b.addRunArtifact(b.addTest(.{ .root_module = stable_runtime }));
    const borrow_returns = b.createModule(.{ .root_source_file = source.path(b, "test/v2/borrow_returns.zig"), .target = b.graph.host, .optimize = host_mode, .imports = &.{.{ .name = "horos", .module = horos }} });
    const stable_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/stable_source.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "kosmos", .module = host_kosmos }, .{ .name = "stable_runtime", .module = stable_runtime }, .{ .name = "horos_data", .module = source_data }, .{ .name = "horos", .module = horos }, .{ .name = "borrow_return_fixtures", .module = borrow_returns } },
    }) });
    const stable_source = b.addRunArtifact(stable_test);
    const native_checks = b.step("check-native", "Check native storage, source semantics, sessions and restore without an interpreter");
    native_checks.dependOn(&oracle_tests.step);
    const driver_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test_semantic_driver.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "horos_data", .module = source_data }, .{ .name = "horos", .module = horos }, .{ .name = "packaged_runtime", .module = packaged_runtime } },
    }) });
    const run_driver_tests = b.addRunArtifact(driver_tests);
    b.step("check-semantic-driver", "Check packaged artifact admission and guest/outer bridge framing").dependOn(&run_driver_tests.step);
    native_checks.dependOn(&run_driver_tests.step);
    const semantic_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test_semantic.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "horos_data", .module = source_data }, .{ .name = "horos", .module = horos } },
    }) });
    native_checks.dependOn(&b.addRunArtifact(semantic_tests).step);
    const specialization_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test_semantic_specialization.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "horos_data", .module = source_data }, .{ .name = "horos", .module = horos } },
    }) });
    const run_specialization_tests = b.addRunArtifact(specialization_tests);
    b.step("check-semantic-specialization", "Check specialized transitions, scalar storage and retained reconstruction")
        .dependOn(&run_specialization_tests.step);
    native_checks.dependOn(&run_specialization_tests.step);
    native_checks.dependOn(&stable_source.step);
    native_checks.dependOn(&run_native_tests.step);
    const public_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/native_publication.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "kosmos", .module = host_kosmos }, .{ .name = "horos", .module = horos } },
    }) });
    const public_checks = b.addRunArtifact(public_test);
    native_checks.dependOn(&public_checks.step);
    b.step("check-publication", "Check native public checkpoint recovery and receipt custody").dependOn(&public_checks.step);
    const wasm_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = profile.target, .cpu_features = profile.cpu }) catch @panic("invalid kernel target"));
    const wasm_data = b.createModule(.{
        .root_source_file = source.path(b, "src/data/root.zig"),
        .target = wasm_target,
        .optimize = kernel_mode,
    });
    const current_runtime = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = kernel_mode,
        .imports = &.{.{ .name = "horos_data", .module = wasm_data }},
    });
    current_runtime.addImport("packaged_runtime", b.createModule(.{ .root_source_file = runtime_source, .target = wasm_target, .optimize = kernel_mode }));
    const current_options = b.addOptions();
    current_options.addOption(usize, "input_capacity", b.option(usize, "input-capacity", "Initial current input budget") orelse profile.defaults.input);
    current_options.addOption(usize, "working_capacity", b.option(usize, "working-capacity", "Initial current working budget and backing") orelse profile.defaults.working);
    current_options.addOption(usize, "output_capacity", b.option(usize, "output-capacity", "Initial current output budget") orelse profile.defaults.output);
    const current_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = wasm_target,
        .optimize = kernel_mode,
        .imports = &.{ .{ .name = "runtime", .module = current_runtime }, .{ .name = "horos_data", .module = wasm_data } },
    });
    current_module.addOptions("kernel_options", current_options);
    const current_kernel = b.addExecutable(.{ .name = "kosmos-kernel", .root_module = current_module });
    current_kernel.entry = .disabled;
    current_kernel.use_llvm = profile.wasmBackend == .llvm;
    current_kernel.use_lld = profile.wasmLinker == .lld;
    // Retain exactly the ABI functions; -rdynamic additionally exports
    // linker internals such as __stack_pointer in Zig 0.17.
    current_module.export_symbol_names = &.{
        "world_abi_version",      "world_initialize",      "world_set_limits",
        "world_input_ptr",        "world_input_capacity",  "world_prepare_input",
        "world_output_ptr",       "world_output_len",      "world_error_ptr",
        "world_error_len",        "world_prepared_handle", "world_session_handle",
        "world_working_live",     "world_working_peak",    "world_prepare",
        "world_release_prepared", "world_invoke",          "world_start",
        "world_restore",          "world_drive",           "world_checkpoint",
        "world_close",
    };
    current_kernel.export_memory = true;
    current_kernel.stack_size = profile.stackBytes;
    current_kernel.max_memory = b.option(u64, "maximum-memory", "Current wasm32 memory maximum in whole pages") orelse profile.maximumMemoryBytes;
    var features: std.ArrayList([]const u8) = .empty;
    for (wasm_target.result.cpu.arch.allFeaturesList(), 0..) |feature, index| {
        if (wasm_target.result.cpu.features.isEnabled(@intCast(index)))
            features.append(b.allocator, feature.name) catch @panic("out of memory");
    }
    if (features.items.len != profile.features.len) @panic("resolved kernel features differ from the qualified profile");
    for (features.items, profile.features) |actual, expected| {
        if (!std.mem.eql(u8, actual, expected)) @panic("resolved kernel features differ from the qualified profile");
    }
    const build_profile = b.addWriteFiles().add("kernel-profile.json", std.json.Stringify.valueAlloc(b.allocator, .{
        .target = profile.target,
        .mode = kernel_mode,
        .backend = profile.wasmBackend,
        .linker = profile.wasmLinker,
        .cpu = wasm_target.result.cpu.model.name,
        .features = features.items,
        .stackBytes = current_kernel.stack_size.?,
        .maximumMemoryBytes = current_kernel.max_memory.?,
    }, .{}) catch @panic("out of memory"));
    const installed_profile = b.addInstallFileWithDir(build_profile, .prefix, "kernel-profile.json");
    b.step("build-kernel", "Build the generic ABI 3 kernel")
        .dependOn(&b.addInstallFileWithDir(current_kernel.getEmittedBin(), .prefix, "kosmos-kernel.wasm").step);
    const runtime_package = b.step("build-runtime", "Build the standalone current JavaScript/kernel package");
    runtime_package.dependOn(&installed_profile.step);
    // One explicit npm file list owns the optional package's shipped surface.
    // Repeated builds may retain old outputs, but those never enter a new package.
    const npm_package = std.json.parseFromSliceLeaky(struct { files: []const []const u8 }, b.allocator, @embedFile("package.json"), .{ .ignore_unknown_fields = true }) catch @panic("invalid package file list");
    for (npm_package.files) |path| {
        const file = if (std.mem.eql(u8, path, "kosmos-kernel.wasm")) current_kernel.getEmittedBin() else b.path(path);
        runtime_package.dependOn(&b.addInstallFileWithDir(file, .prefix, b.fmt("runtime/{s}", .{path})).step);
    }
    const fixture = b.addExecutable(.{ .name = "current-fixtures", .root_module = b.createModule(.{
        .root_source_file = b.path("test/current/fixtures.zig"),
        .target = b.graph.host,
        .optimize = host_mode,
        .imports = &.{ .{ .name = "kosmos", .module = host_kosmos }, .{ .name = "horos", .module = horos } },
    }) });
    const current_fixtures = b.addInstallArtifact(fixture, .{ .dest_dir = .{ .override = .{ .custom = "current/bin" } } });
    const native_input = b.addRunArtifact(fixture);
    native_input.addArgs(&.{ "image", "install" });
    b.step("emit-native-input", "Emit the shared native public-consumer input").dependOn(&b.addInstallFileWithDir(native_input.captureStdOut(.{}), .prefix, "native-consumer.bpi3").step);
    const current_package_check = b.addSystemCommand(&.{"node"});
    current_package_check.addFileArg2(b.path("test/current/package.mjs"), .{});
    current_package_check.addDirectoryArg2(b.graph.path(.install_prefix, "runtime"), .{ .make_absolute = true });
    current_package_check.addFileArg2(fixture.getEmittedBin(), .{ .make_absolute = true });
    current_package_check.step.dependOn(runtime_package);
    current_package_check.step.dependOn(&current_fixtures.step);
    current_package_check.has_side_effects = true;
    b.step("check-package", "Run the current API and CLI from an extracted package")
        .dependOn(&current_package_check.step);
    const current_check = b.addSystemCommand(&.{"node"});
    current_check.addFileArg2(b.path("test/current/kernel.mjs"), .{});
    current_check.addFileArg2(current_kernel.getEmittedBin(), .{});
    current_check.addFileArg2(fixture.getEmittedBin(), .{ .make_absolute = true });
    current_check.step.dependOn(&current_fixtures.step);
    current_check.has_side_effects = true;
    b.step("check-kernel", "Check ABI 3 and current native/Node transfer").dependOn(&current_check.step);
    const source_examples = b.addRunFile(.zig_exe);
    source_examples.addArg("build");
    source_examples.addDirectoryArg2(.zig_lib, .{ .prefix = "--zig-lib=", .make_absolute = true });
    source_examples.addArgs(&.{ "emit-examples", "--build-file" });
    source_examples.addFileArg2(source.path(b, "build.zig"), .{});
    source_examples.addArgs(&.{ b.fmt("-Doptimize={s}", .{profile.hostMode}), "--prefix" });
    source_examples.addDirectoryArg2(b.graph.path(.install_prefix, "source"), .{ .make_absolute = true });
    source_examples.addArg("--cache-dir");
    source_examples.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, "source-examples"), .{ .make_absolute = true });
    const source_agreement = b.addSystemCommand(&.{"node"});
    source_agreement.addFileArg2(b.path("test/current/source_agreement.mjs"), .{});
    source_agreement.addFileArg2(current_kernel.getEmittedBin(), .{});
    source_agreement.addFileArg2(fixture.getEmittedBin(), .{ .make_absolute = true });
    source_agreement.addDirectoryArg2(b.graph.path(.install_prefix, "source"), .{ .make_absolute = true });
    source_agreement.addFileArg2(source.path(b, "test/v2/source_oracle.mjs"), .{ .make_absolute = true });
    source_agreement.step.dependOn(&source_examples.step);
    source_agreement.step.dependOn(&current_fixtures.step);
    source_agreement.has_side_effects = true;
    b.step("check-source", "Compare current native/WASM execution with independent source semantics")
        .dependOn(&source_agreement.step);
    const capacity = b.addSystemCommand(&.{"node"});
    capacity.addFileArg2(b.path("test/current/capacity.mjs"), .{});
    capacity.addFileArg2(current_kernel.getEmittedBin(), .{});
    capacity.addFileArg2(fixture.getEmittedBin(), .{ .make_absolute = true });
    capacity.step.dependOn(&current_fixtures.step);
    capacity.has_side_effects = true;
    b.step("check-capacity", "Check all current arena limits, physical memory and unchanged retries")
        .dependOn(&capacity.step);
    const current_browser = b.addSystemCommand(&.{"node"});
    current_browser.addFileArg2(b.path("test/current/browser.mjs"), .{});
    current_browser.addFileArg2(current_kernel.getEmittedBin(), .{});
    current_browser.addFileArg2(fixture.getEmittedBin(), .{ .make_absolute = true });
    current_browser.step.dependOn(&current_fixtures.step);
    current_browser.has_side_effects = true;
    b.step("check-browser", "Check real browser Worker/native transfer on Chromium and Firefox").dependOn(&current_browser.step);
    const current_codecs = b.addSystemCommand(&.{ "node", "--test" });
    current_codecs.addFileArg2(b.path("test/current/codec.test.mjs"), .{});
    current_codecs.addFileArg2(b.path("test/current/byte_contracts.test.mjs"), .{});
    current_codecs.addFileArg2(b.path("test/current/wasm.test.mjs"), .{});
    current_codecs.addFileArg2(b.path("test/current/file_input.test.mjs"), .{});
    current_codecs.addFileArg2(b.path("test/current/runtime_bundle.test.mjs"), .{});
    current_codecs.has_side_effects = true;
    b.step("check-codecs", "Check current browser-neutral byte ownership and value contracts").dependOn(&current_codecs.step);
    const activation_wasm_store = b.createModule(.{
        .root_source_file = b.path("src/interpreter_v2/activation_slots.zig"),
        .target = wasm_target,
        .optimize = .safe,
        .imports = &.{.{ .name = "horos_data", .module = wasm_data }},
    });
    const activation_wasm = b.addExecutable(.{ .name = "activation-storage-test", .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/activation_storage_wasm.zig"),
        .target = wasm_target,
        .optimize = .safe,
        .imports = &.{.{ .name = "activation_slots", .module = activation_wasm_store }},
    }) });
    activation_wasm.entry = .disabled;
    activation_wasm.rdynamic = true;
    activation_wasm.export_memory = true;
    activation_wasm.stack_size = 65536;
    activation_wasm.max_memory = 4 << 20;
    const activation_wasm_run = b.addSystemCommand(&.{"node"});
    activation_wasm_run.addFileArg2(b.path("test/v2/activation_storage_wasm.mjs"), .{});
    activation_wasm_run.addFileArg2(activation_wasm.getEmittedBin(), .{});
    b.step("check-activation-storage-wasm", "Check storage on import-free unshared wasm32")
        .dependOn(&activation_wasm_run.step);
    const check = b.step("check", "Check current native, host, portable and package contracts");
    const zig17 = b.step("check-zig17", "Check pointer-borrow diagnostics and qualified storage ownership");
    const borrow_probe = b.addExecutable(.{
        .name = "kosmos-borrow-diagnostics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interpreter_v2/borrow_diagnostics.zig"),
            .target = b.graph.host,
            // Keep the named assertion frame in intentional-panic diagnostics.
            .optimize = .debug,
            .imports = &.{.{ .name = "horos_data", .module = host_data }},
        }),
    });
    const borrow_check = b.addRunArtifact(borrow_probe);
    borrow_check.addArg("check");
    borrow_check.addArtifactArg2(borrow_probe, .{ .make_absolute = true });
    zig17.dependOn(&borrow_check.step);
    check.dependOn(zig17);
    check.dependOn(native_checks);
    check.dependOn(&activation_wasm_run.step);
    check.dependOn(&current_check.step);
    check.dependOn(&source_agreement.step);
    check.dependOn(&capacity.step);
    check.dependOn(&current_browser.step);
    check.dependOn(&current_codecs.step);
    check.dependOn(&current_package_check.step);
}
