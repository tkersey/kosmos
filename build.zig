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
    configureReleaseTools(b);
    const options = configureOptions(b);
    const dependencies = configureDependencies(b, options) orelse return;
    const storage_checks = configureStorageChecks(b, options, dependencies);
    const host_modules = configureHostModules(b, options, dependencies);
    const artifact_images = configureArtifactImages(b, options, host_modules);
    const runtime_modules = configureRuntimeModules(
        b,
        options,
        dependencies,
        host_modules,
        artifact_images,
    );
    const publication = configurePublication(
        b,
        options,
        dependencies,
        host_modules,
        runtime_modules,
    );
    const baseline = configureBaseline(b, host_modules);
    configureEconomy(b, options, host_modules, runtime_modules, baseline);
    const sessions = configureSessions(b, options, dependencies, host_modules, publication);
    const driver = configureDriver(b, host_modules, runtime_modules, baseline);
    configureSemantics(b, storage_checks, host_modules, baseline, sessions, driver);
    configurePublicTests(b, host_modules, publication, driver);
    const wasm_modules = configureWasmModules(b, options, dependencies, runtime_modules);
    const kernel = configureKernel(b, options, wasm_modules);
    const runtime_profile = configureRuntimeProfile(b, options, wasm_modules, kernel);
    const packages = configurePackages(b, kernel, runtime_profile);
    const fixtures = configureFixtures(b, options, host_modules, publication);
    const foreign_checks = configureForeignChecks(b, kernel, packages, fixtures);
    const source_checks = configureSourceChecks(b, options, dependencies, kernel, fixtures);
    const portable_checks = configurePortableChecks(b, kernel, fixtures);
    const activation = configureActivation(b, wasm_modules);
    configureQualification(
        b,
        dependencies,
        driver,
        foreign_checks,
        source_checks,
        portable_checks,
        activation,
    );
}

const SessionGroup = enum { behavior, ownership, regressions };
const SourceGroup = enum { first, second };
const FixtureProfile = enum { full, prepared_only };

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    profile: Profile,
    use_packaged_runtime: bool,
    session_group: ?SessionGroup,
    source_group: ?SourceGroup,
    fixture_profile: FixtureProfile,
    economy_workload: ?[]const u8,
    input_capacity: usize,
    working_capacity: usize,
    output_capacity: usize,
    maximum_memory: u64,
    package: @TypeOf(@import("build.zig.zon")),
    kernel_mode: std.lang.Optimize,
};

fn configureOptions(b: *std.Build) Options {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = std.json.parseFromSliceLeaky(
        Profile,
        b.allocator,
        @embedFile("build-profile.json"),
        .{},
    ) catch @panic("invalid runtime profile");
    // Declare options before a cold lazy dependency fetch can return.
    const use_packaged_runtime = b.option(
        bool,
        "packaged-runtime",
        "Use the source/compiler/content-bound evaluator artifact",
    ) orelse true;
    const session_group = b.option(
        SessionGroup,
        "session-group",
        "Select independent session qualification cases (default: all)",
    );
    const source_group = b.option(
        SourceGroup,
        "source-group",
        "Select an exhaustive half of the source fixtures (default: all)",
    );
    const fixture_profile = b.option(
        FixtureProfile,
        "fixture-profile",
        "Select native fixture commands (default: full)",
    ) orelse .full;
    const economy_workload = b.option(
        []const u8,
        "economy-workload",
        "Select one semantic economy workload",
    );
    const capacities = configureCapacities(b, profile);
    const package = @import("build.zig.zon");
    const kernel_mode = std.meta.stringToEnum(
        std.lang.Optimize,
        profile.kernelMode,
    ) orelse @panic("invalid kernel mode");

    return .{
        .target = target,
        .optimize = optimize,
        .profile = profile,
        .use_packaged_runtime = use_packaged_runtime,
        .session_group = session_group,
        .source_group = source_group,
        .fixture_profile = fixture_profile,
        .economy_workload = economy_workload,
        .input_capacity = capacities.input_capacity,
        .working_capacity = capacities.working_capacity,
        .output_capacity = capacities.output_capacity,
        .maximum_memory = capacities.maximum_memory,
        .package = package,
        .kernel_mode = kernel_mode,
    };
}

const Capacities = struct {
    input_capacity: usize,
    working_capacity: usize,
    output_capacity: usize,
    maximum_memory: u64,
};

fn configureCapacities(b: *std.Build, profile: Profile) Capacities {
    const input_capacity = b.option(
        usize,
        "input-capacity",
        "Initial current input budget",
    ) orelse profile.defaults.input;
    const working_capacity = b.option(
        usize,
        "working-capacity",
        "Initial current working allocation budget",
    ) orelse profile.defaults.working;
    const output_capacity = b.option(
        usize,
        "output-capacity",
        "Initial current output budget",
    ) orelse profile.defaults.output;
    const maximum_memory = b.option(
        u64,
        "maximum-memory",
        "Current wasm32 memory maximum in whole pages",
    ) orelse profile.maximumMemoryBytes;
    return .{
        .input_capacity = input_capacity,
        .working_capacity = working_capacity,
        .output_capacity = output_capacity,
        .maximum_memory = maximum_memory,
    };
}

const Dependencies = struct {
    source: std.Build.LazyPath,
    data: *std.Build.Module,
    host_data: *std.Build.Module,
    public_kosmos: *std.Build.Module,
};

fn configureDependencies(b: *std.Build, options: Options) ?Dependencies {
    const supplied_source = b.option(
        std.Build.LazyPath,
        "horos-source",
        "Override the pinned Horos source",
    ) orelse pinned: {
        const dependency = b.lazyDependency("horos", .{
            .target = options.target,
            .optimize = options.optimize,
            .@"data-only" = true,
        }) orelse return null;
        break :pinned dependency.path("");
    };
    if (supplied_source == .cwd_relative and
        !std.Io.Dir.path.isAbsolute(supplied_source.cwd_relative))
        @panic("Horos source path must be absolute");
    // Fetch captures the selected package without executing its build code.
    // Every compiler/emitter consumes the authenticated cache snapshot, never
    // the caller's mutable source directory after verification.
    const admission = b.addRunFile(.zig_exe);
    admission.setCwd(b.graph.path(.global_cache, ""));
    admission.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", ".");
    admission.addArg("fetch");
    admission.addDirectoryArg2(supplied_source, .{ .make_absolute = true });
    admission.expectStdOutEqual(options.package.dependencies.horos.hash ++ "\n");
    admission.has_side_effects = true;
    const snapshot = b.addSystemCommand(&.{ "tar", "-xzf" });
    // Hash only extraction inputs, not caller run IDs or unrelated credentials.
    // PATH still selects tar's decompressor; ambient archive options stay absent.
    snapshot.clearEnvironment();
    if (b.graph.environ_map.get("PATH")) |path| snapshot.setEnvironmentVariable("PATH", path);
    snapshot.addFileArg2(b.graph.path(
        .global_cache,
        "p/" ++ options.package.dependencies.horos.hash ++ ".tar.gz",
    ), .{ .make_absolute = true });
    snapshot.addArgs(&.{ "--strip-components=1", "--no-same-owner", "-C" });
    const source = snapshot.addOutputDirectoryArg2("horos", .{});
    snapshot.step.dependOn(&admission.step);
    const data = b.createModule(.{
        .root_source_file = source.path(b, "src/data/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });
    const host_data = if (options.target.query.isNative()) data else b.createModule(.{
        .root_source_file = source.path(b, "src/data/root.zig"),
        .target = b.graph.host,
        .optimize = options.optimize,
    });
    const public_kosmos = b.addModule("kosmos", .{
        .root_source_file = b.path("src/root.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "horos_data", .module = data }},
    });

    return .{
        .source = source,
        .data = data,
        .host_data = host_data,
        .public_kosmos = public_kosmos,
    };
}

const StorageChecks = struct {
    run_native_tests: *std.Build.Step.Run,
};

fn configureStorageChecks(
    b: *std.Build,
    options: Options,
    dependencies: Dependencies,
) StorageChecks {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/interpreter_v2/tests.zig"),
        .target = b.graph.host,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "horos_data", .module = dependencies.host_data }},
    }) });
    const run_native_tests = b.addRunArtifact(tests);
    b.step("build-storage-check", "Build the native storage test artifact")
        .dependOn(&tests.step);
    run_native_tests.has_side_effects = true;
    b.step("check-storage", "Check current private storage and allocation contracts")
        .dependOn(&run_native_tests.step);
    const activation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/interpreter_v2/activation_slots_tests.zig"),
        .target = b.graph.host,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "horos_data", .module = dependencies.host_data }},
    }) });
    const run_activation_tests = b.addRunArtifact(activation_tests);
    run_activation_tests.has_side_effects = true;
    b.step("check-activation-storage", "Check stable activation storage and failure atomicity")
        .dependOn(&run_activation_tests.step);

    return .{ .run_native_tests = run_native_tests };
}

const HostModules = struct {
    host_mode: std.lang.Optimize,
    source_data: *std.Build.Module,
    horos: *std.Build.Module,
};

fn configureHostModules(b: *std.Build, options: Options, dependencies: Dependencies) HostModules {
    const host_mode = std.meta.stringToEnum(
        std.lang.Optimize,
        options.profile.hostMode,
    ) orelse @panic("invalid host mode");
    const source_data = if (host_mode == options.optimize)
        dependencies.host_data
    else
        b.createModule(
            .{
                .root_source_file = dependencies.source.path(b, "src/data/root.zig"),
                .target = b.graph.host,
                .optimize = host_mode,
            },
        );
    const horos = b.createModule(
        .{
            .root_source_file = dependencies.source.path(b, "src/root.zig"),
            .target = b.graph.host,
            .optimize = host_mode,
            .imports = &.{.{
                .name = "horos_data",
                .module = source_data,
            }},
        },
    );
    dependencies.public_kosmos.addImport("horos", if (options.target.query.isNative() and
        host_mode == options.optimize) horos else b.createModule(
        .{
            .root_source_file = dependencies.source.path(b, "src/root.zig"),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{
                .name = "horos_data",
                .module = dependencies.data,
            }},
        },
    ));

    return .{ .host_mode = host_mode, .source_data = source_data, .horos = horos };
}

const ArtifactImages = struct {
    semantic_artifact: std.Build.LazyPath,
    selected_artifact: std.Build.LazyPath,
};

fn configureArtifactImages(
    b: *std.Build,
    options: Options,
    host_modules: HostModules,
) ArtifactImages {
    const artifact_options = b.addOptions();
    artifact_options.addOption(
        []const u8,
        "horos_package",
        options.package.dependencies.horos.hash,
    );
    // Qualification rebuilds the evaluator from source and compares exact
    // packaged bytes. A downstream consumer checks the shipped source/compiler/
    // content bindings instead of recompiling that host generator. Runtime
    // artifact and guest admission are identical in both cases.
    const artifact_emitter = b.addExecutable(
        .{
            .name = "kosmos-semantic-artifact",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/semantic_artifact.zig"),
                    .target = b.graph.host,
                    .optimize = host_modules.host_mode,
                    .imports = &.{ .{ .name = "horos_data", .module = host_modules.source_data }, .{
                        .name = "horos",
                        .module = host_modules.horos,
                    } },
                },
            ),
        },
    );
    artifact_emitter.root_module.addOptions("artifact_options", artifact_options);
    const emit_artifact = b.addRunArtifact(artifact_emitter);
    const semantic_artifact = emit_artifact.captureStdOut(.{});
    const selected_artifact = if (options.use_packaged_runtime) packaged: {
        const emitter = b.addExecutable(
            .{
                .name = "kosmos-packaged-artifact",
                .root_module = b.createModule(
                    .{
                        .root_source_file = b.path("src/semantic_packaged.zig"),
                        .target = b.graph.host,
                        .optimize = host_modules.host_mode,
                    },
                ),
            },
        );
        emitter.root_module.addOptions("artifact_options", artifact_options);
        break :packaged b.addRunArtifact(emitter).captureStdOut(.{});
    } else semantic_artifact;

    return .{ .semantic_artifact = semantic_artifact, .selected_artifact = selected_artifact };
}

const RuntimeModules = struct {
    runtime_source: std.Build.LazyPath,
    packaged_runtime: *std.Build.Module,
    rebuilt_directory: std.Build.LazyPath,
};

fn configureRuntimeModules(
    b: *std.Build,
    options: Options,
    dependencies: Dependencies,
    host_modules: HostModules,
    artifact_images: ArtifactImages,
) RuntimeModules {
    const runtime_files = b.addWriteFiles();
    _ = runtime_files.addCopyFile(artifact_images.selected_artifact, "semantic-core.kar");
    const runtime_source = runtime_files.add(
        "runtime.zig",
        "pub const bytes = @embedFile(\"semantic-core.kar\");\n",
    );
    const packaged_runtime = b.createModule(.{
        .root_source_file = runtime_source,
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
    });
    const rebuilt_directory = if (!options.use_packaged_runtime)
        runtime_files.getDirectory()
    else rebuilt: {
        const files = b.addWriteFiles();
        _ = files.addCopyFile(artifact_images.semantic_artifact, "semantic-core.kar");
        break :rebuilt files.getDirectory();
    };
    dependencies.public_kosmos.addImport(
        "packaged_runtime",
        if (options.target.query.isNative()) packaged_runtime else b.createModule(
            .{
                .root_source_file = runtime_source,
                .target = options.target,
                .optimize = options.optimize,
            },
        ),
    );
    b.step("semantic-artifact", "Compile and admit the reproducible portable evaluator bundle")
        .dependOn(&b.addInstallFile(artifact_images.semantic_artifact, "semantic-core.kar").step);

    return .{
        .runtime_source = runtime_source,
        .packaged_runtime = packaged_runtime,
        .rebuilt_directory = rebuilt_directory,
    };
}

const Publication = struct {
    host_kosmos: *std.Build.Module,
};

fn configurePublication(
    b: *std.Build,
    options: Options,
    dependencies: Dependencies,
    host_modules: HostModules,
    runtime_modules: RuntimeModules,
) Publication {
    const host_kosmos = if (options.target.query.isNative() and
        host_modules.host_mode == options.optimize) dependencies.public_kosmos else b.createModule(
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = b.graph.host,
            .optimize = host_modules.host_mode,
            .imports = &.{.{
                .name = "horos_data",
                .module = host_modules.source_data,
            }},
        },
    );
    if (host_kosmos != dependencies.public_kosmos) {
        host_kosmos.addImport("packaged_runtime", runtime_modules.packaged_runtime);
        host_kosmos.addImport("horos", host_modules.horos);
    }
    const publication_bench = b.addExecutable(
        .{
            .name = "publication-bench",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("test/v2/publication_bench.zig"),
                    .target = b.graph.host,
                    .optimize = host_modules.host_mode,
                    .imports = &.{ .{
                        .name = "kosmos",
                        .module = host_kosmos,
                    }, .{ .name = "horos", .module = host_modules.horos } },
                },
            ),
        },
    );
    const run_publication_bench = b.addRunArtifact(publication_bench);
    run_publication_bench.has_side_effects = true;
    b.step(
        "bench-publication",
        "Measure native preparation, publication, receipt custody and restore (JSONL)",
    )
        .dependOn(&b.addInstallFile(
        run_publication_bench.captureStdOut(.{}),
        "publication.jsonl",
    ).step);
    // Immutable historical comparison input. Only qualification and benchmark
    // roots depend on this fetch; production has no native guest evaluator.

    return .{ .host_kosmos = host_kosmos };
}

const Baseline = struct {
    native_baseline: *std.Build.Module,
};

fn configureBaseline(b: *std.Build, host_modules: HostModules) Baseline {
    const baseline_hash = "kosmos-8.0.0-vcJNB7_PDwCsxCmIN8VIVZsi9fW8qHX7Y5xesXeS6Kn5";
    const baseline_fetch = b.addRunFile(.zig_exe);
    baseline_fetch.setCwd(b.graph.path(.global_cache, ""));
    baseline_fetch.setEnvironmentVariable("ZIG_GLOBAL_CACHE_DIR", ".");
    baseline_fetch.addArgs(&.{
        "fetch",
        "https://github.com/tkersey/kosmos/archive/62279bce8e916e7fe613fe" ++
            "4575b3bc12e530596f.tar.gz",
    });
    baseline_fetch.expectStdOutEqual(baseline_hash ++ "\n");
    baseline_fetch.has_side_effects = true;
    const baseline_unpack = b.addSystemCommand(&.{ "tar", "-xzf" });
    baseline_unpack.clearEnvironment();
    if (b.graph.environ_map.get(
        "PATH",
    )) |path| baseline_unpack.setEnvironmentVariable("PATH", path);
    baseline_unpack.addFileArg2(b.graph.path(
        .global_cache,
        "p/" ++ baseline_hash ++ ".tar.gz",
    ), .{ .make_absolute = true });
    baseline_unpack.addArgs(&.{ "--strip-components=2", "--no-same-owner", "-C" });
    const baseline_source = baseline_unpack.addOutputDirectoryArg2("native-baseline", .{});
    baseline_unpack.step.dependOn(&baseline_fetch.step);
    const native_baseline = b.createModule(.{ .root_source_file = baseline_source.path(
        b,
        "src/interpreter_v2/stable_session.zig",
    ), .target = b.graph.host, .optimize = host_modules.host_mode, .imports = &.{.{
        .name = "horos_data",
        .module = host_modules.source_data,
    }} });

    return .{ .native_baseline = native_baseline };
}

fn configureEconomy(
    b: *std.Build,
    options: Options,
    host_modules: HostModules,
    runtime_modules: RuntimeModules,
    baseline: Baseline,
) void {
    const economy_bench = b.addExecutable(
        .{
            .name = "semantic-economy",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("bench_semantics.zig"),
                    .target = b.graph.host,
                    .optimize = host_modules.host_mode,
                    .imports = &.{ .{
                        .name = "native_baseline",
                        .module = baseline.native_baseline,
                    }, .{
                        .name = "horos_data",
                        .module = host_modules.source_data,
                    }, .{ .name = "horos", .module = host_modules.horos }, .{
                        .name = "packaged_runtime",
                        .module = runtime_modules.packaged_runtime,
                    } },
                },
            ),
        },
    );
    const run_economy_bench = b.addRunArtifact(economy_bench);
    if (options.economy_workload) |name| run_economy_bench.addArg(name);
    run_economy_bench.has_side_effects = true;
    b.step(
        "bench-semantics",
        "Measure matched native, bootstrap, generic and specialized realizations (JSONL)",
    )
        .dependOn(&run_economy_bench.step);
}

const Sessions = struct {
    stable_source: *std.Build.Step.Run,
};

fn configureSessions(
    b: *std.Build,
    options: Options,
    dependencies: Dependencies,
    host_modules: HostModules,
    publication: Publication,
) Sessions {
    const authoring_client = b.createModule(.{
        .root_source_file = dependencies.source.path(b, "examples/authoring_client.zig"),
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
        .imports = &.{.{ .name = "horos", .module = host_modules.horos }},
    });
    const borrow_returns = b.createModule(
        .{
            .root_source_file = dependencies.source.path(b, "test/v2/borrow_returns.zig"),
            .target = b.graph.host,
            .optimize = host_modules.host_mode,
            .imports = &.{.{ .name = "horos", .module = host_modules.horos }},
        },
    );
    const stable_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/stable_source.zig"),
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
        .imports = &.{ .{
            .name = "kosmos",
            .module = publication.host_kosmos,
        }, .{ .name = "horos_data", .module = host_modules.source_data }, .{
            .name = "horos",
            .module = host_modules.horos,
        }, .{
            .name = "borrow_return_fixtures",
            .module = borrow_returns,
        }, .{
            .name = "authoring_client",
            .module = authoring_client,
        } },
    }), .filters = if (options.session_group) |group| switch (group) {
        .behavior => &.{"stable_source.test.behavior: "},
        .ownership => &.{"stable_source.test.ownership: "},
        .regressions => &.{"source_regressions."},
    } else &.{} });
    const stable_source = b.addRunArtifact(stable_test);
    stable_source.has_side_effects = true;
    b.step(
        "check-sessions",
        "Check current public session behavior, ownership and failure atomicity",
    )
        .dependOn(&stable_source.step);
    b.step("build-session-check", "Build the retained session test executable")
        .dependOn(&b.addInstallArtifact(stable_test, .{
        .dest_dir = .{ .override = .{ .custom = "verification" } },
        .dest_sub_path = "sessions",
    }).step);

    return .{ .stable_source = stable_source };
}

const Driver = struct {
    native_checks: *std.Build.Step,
};

fn configureDriver(
    b: *std.Build,
    host_modules: HostModules,
    runtime_modules: RuntimeModules,
    baseline: Baseline,
) Driver {
    const native_checks = b.step(
        "check-native",
        "Check native storage, source semantics, sessions and restore without an interpreter",
    );
    const retained_files = b.addWriteFiles();
    _ = retained_files.addCopyFile(b.path("src/semantic-core.kar"), "semantic-core.kar");
    const retained_runtime = b.createModule(.{
        .root_source_file = retained_files.add(
            "runtime.zig",
            "pub const bytes = @embedFile(\"semantic-core.kar\");\n",
        ),
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
    });
    const driver_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test_semantic_driver.zig"),
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
        .imports = &.{ .{ .name = "native_baseline", .module = baseline.native_baseline }, .{
            .name = "horos_data",
            .module = host_modules.source_data,
        }, .{ .name = "horos", .module = host_modules.horos }, .{
            .name = "packaged_runtime",
            .module = retained_runtime,
        } },
    }) });
    const run_driver_tests = b.addRunArtifact(driver_tests);
    const build_driver = b.step(
        "build-semantic-driver-check",
        "Build the native semantic driver test artifact and independently rebuilt core",
    );
    build_driver.dependOn(&driver_tests.step);
    runtime_modules.rebuilt_directory.addStepDependencies(build_driver);
    run_driver_tests.setCwd(runtime_modules.rebuilt_directory);
    run_driver_tests.has_side_effects = true;
    b.step(
        "check-semantic-driver",
        "Check packaged artifact admission and guest/outer bridge framing",
    ).dependOn(&run_driver_tests.step);
    native_checks.dependOn(&run_driver_tests.step);

    return .{ .native_checks = native_checks };
}

fn configureSemantics(
    b: *std.Build,
    storage_checks: StorageChecks,
    host_modules: HostModules,
    baseline: Baseline,
    sessions: Sessions,
    driver: Driver,
) void {
    const semantic_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test_semantic.zig"),
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
        .imports = &.{ .{ .name = "native_baseline", .module = baseline.native_baseline }, .{
            .name = "horos_data",
            .module = host_modules.source_data,
        }, .{ .name = "horos", .module = host_modules.horos } },
    }) });
    const run_semantic_tests = b.addRunArtifact(semantic_tests);
    b.step("build-semantics-check", "Build the native semantic correspondence test artifact")
        .dependOn(&semantic_tests.step);
    run_semantic_tests.has_side_effects = true;
    b.step("check-semantics", "Check portable semantics against the immutable historical evaluator")
        .dependOn(&run_semantic_tests.step);
    driver.native_checks.dependOn(&run_semantic_tests.step);
    const specialization_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test_semantic_specialization.zig"),
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
        .imports = &.{ .{ .name = "native_baseline", .module = baseline.native_baseline }, .{
            .name = "horos_data",
            .module = host_modules.source_data,
        }, .{ .name = "horos", .module = host_modules.horos } },
    }) });
    const run_specialization_tests = b.addRunArtifact(specialization_tests);
    run_specialization_tests.has_side_effects = true;
    b.step(
        "check-semantic-specialization",
        "Check specialized transitions, scalar storage and retained reconstruction",
    )
        .dependOn(&run_specialization_tests.step);
    driver.native_checks.dependOn(&run_specialization_tests.step);
    driver.native_checks.dependOn(&sessions.stable_source.step);
    driver.native_checks.dependOn(&storage_checks.run_native_tests.step);
}

fn configurePublicTests(
    b: *std.Build,
    host_modules: HostModules,
    publication: Publication,
    driver: Driver,
) void {
    const public_test = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/v2/native_publication.zig"),
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
        .imports = &.{ .{ .name = "kosmos", .module = publication.host_kosmos }, .{
            .name = "horos",
            .module = host_modules.horos,
        } },
    }) });
    const public_checks = b.addRunArtifact(public_test);
    public_checks.has_side_effects = true;
    driver.native_checks.dependOn(&public_checks.step);
    b.step(
        "check-publication",
        "Check native public checkpoint recovery and receipt custody",
    ).dependOn(&public_checks.step);
}

const WasmModules = struct {
    wasm_target: std.Build.ResolvedTarget,
    wasm_data: *std.Build.Module,
    current_module: *std.Build.Module,
};

fn configureWasmModules(
    b: *std.Build,
    options: Options,
    dependencies: Dependencies,
    runtime_modules: RuntimeModules,
) WasmModules {
    const wasm_target = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = options.profile.target,
        .cpu_features = options.profile.cpu,
    }) catch @panic("invalid kernel target"));
    const wasm_data = b.createModule(.{
        .root_source_file = dependencies.source.path(b, "src/data/root.zig"),
        .target = wasm_target,
        .optimize = options.kernel_mode,
    });
    const current_runtime = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = options.kernel_mode,
        .imports = &.{.{ .name = "horos_data", .module = wasm_data }},
    });
    current_runtime.addImport("packaged_runtime", b.createModule(.{
        .root_source_file = runtime_modules.runtime_source,
        .target = wasm_target,
        .optimize = options.kernel_mode,
    }));
    const current_options = b.addOptions();
    current_options.addOption(usize, "input_capacity", options.input_capacity);
    current_options.addOption(usize, "working_capacity", options.working_capacity);
    current_options.addOption(usize, "output_capacity", options.output_capacity);
    const current_module = b.createModule(.{
        .root_source_file = b.path("src/kernel/main.zig"),
        .target = wasm_target,
        .optimize = options.kernel_mode,
        .imports = &.{ .{ .name = "runtime", .module = current_runtime }, .{
            .name = "horos_data",
            .module = wasm_data,
        } },
    });
    current_module.addOptions("kernel_options", current_options);

    return .{
        .wasm_target = wasm_target,
        .wasm_data = wasm_data,
        .current_module = current_module,
    };
}

const Kernel = struct {
    current_kernel: *std.Build.Step.Compile,
};

fn configureKernel(b: *std.Build, options: Options, wasm_modules: WasmModules) Kernel {
    const current_kernel = b.addExecutable(.{
        .name = "kosmos-kernel",
        .root_module = wasm_modules.current_module,
    });
    current_kernel.entry = .disabled;
    current_kernel.use_llvm = options.profile.wasmBackend == .llvm;
    current_kernel.use_lld = options.profile.wasmLinker == .lld;
    // Retain exactly the ABI functions; -rdynamic additionally exports
    // linker internals such as __stack_pointer in Zig 0.17.
    wasm_modules.current_module.export_symbol_names = &.{
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
    current_kernel.stack_size = options.profile.stackBytes;
    current_kernel.max_memory = options.maximum_memory;

    return .{ .current_kernel = current_kernel };
}

const RuntimeProfile = struct {
    build_profile: std.Build.LazyPath,
};

fn configureRuntimeProfile(
    b: *std.Build,
    options: Options,
    wasm_modules: WasmModules,
    kernel: Kernel,
) RuntimeProfile {
    var features: std.ArrayList([]const u8) = .empty;
    for (wasm_modules.wasm_target.result.cpu.arch.allFeaturesList(), 0..) |feature, index| {
        if (wasm_modules.wasm_target.result.cpu.features.isEnabled(@intCast(index)))
            features.append(b.allocator, feature.name) catch @panic("out of memory");
    }
    if (features.items.len != options.profile.features.len) @panic(
        "resolved kernel features differ from the qualified profile",
    );
    for (features.items, options.profile.features) |actual, expected| {
        if (!std.mem.eql(u8, actual, expected)) @panic(
            "resolved kernel features differ from the qualified profile",
        );
    }
    const build_profile = b.addWriteFiles().add(
        "kernel-profile.json",
        std.json.Stringify.valueAlloc(
            b.allocator,
            .{
                .target = options.profile.target,
                .mode = options.kernel_mode,
                .backend = options.profile.wasmBackend,
                .linker = options.profile.wasmLinker,
                .cpu = wasm_modules.wasm_target.result.cpu.model.name,
                .features = features.items,
                .stackBytes = kernel.current_kernel.stack_size.?,
                .maximumMemoryBytes = kernel.current_kernel.max_memory.?,
            },
            .{},
        ) catch @panic("out of memory"),
    );

    return .{ .build_profile = build_profile };
}

const Packages = struct {
    runtime_package: *std.Build.Step,
};

fn configurePackages(b: *std.Build, kernel: Kernel, runtime_profile: RuntimeProfile) Packages {
    const installed_profile = b.addInstallFileWithDir(
        runtime_profile.build_profile,
        .prefix,
        "kernel-profile.json",
    );
    b.step("build-kernel", "Build the generic ABI 3 kernel")
        .dependOn(&b.addInstallFileWithDir(
        kernel.current_kernel.getEmittedBin(),
        .prefix,
        "kosmos-kernel.wasm",
    ).step);
    const runtime_package = b.step(
        "build-runtime",
        "Build the standalone current JavaScript/kernel package",
    );
    runtime_package.dependOn(&installed_profile.step);
    // One explicit npm file list owns the optional package's shipped surface.
    // Repeated builds may retain old outputs, but those never enter a new package.
    const npm_package = std.json.parseFromSliceLeaky(
        struct { files: []const []const u8 },
        b.allocator,
        @embedFile("package.json"),
        .{ .ignore_unknown_fields = true },
    ) catch @panic("invalid package file list");
    for (npm_package.files) |path| {
        const file = if (std.mem.eql(
            u8,
            path,
            "kosmos-kernel.wasm",
        )) kernel.current_kernel.getEmittedBin() else b.path(path);
        runtime_package.dependOn(&b.addInstallFileWithDir(
            file,
            .prefix,
            b.fmt("runtime/{s}", .{path}),
        ).step);
    }

    return .{ .runtime_package = runtime_package };
}

const Fixtures = struct {
    fixture: *std.Build.Step.Compile,
    current_fixtures: *std.Build.Step.InstallArtifact,
};

fn configureFixtures(
    b: *std.Build,
    options: Options,
    host_modules: HostModules,
    publication: Publication,
) Fixtures {
    const fixture_options = b.addOptions();
    fixture_options.addOption(bool, "prepared_only", options.fixture_profile == .prepared_only);
    const fixture = b.addExecutable(.{ .name = "current-fixtures", .root_module = b.createModule(.{
        .root_source_file = b.path("test/current/fixtures.zig"),
        .target = b.graph.host,
        .optimize = host_modules.host_mode,
        .imports = &.{ .{ .name = "kosmos", .module = publication.host_kosmos }, .{
            .name = "horos",
            .module = host_modules.horos,
        } },
    }) });
    fixture.root_module.addOptions("fixture_options", fixture_options);
    const current_fixtures = b.addInstallArtifact(fixture, .{ .dest_dir = .{
        .override = .{ .custom = "current/bin" },
    } });
    const native_input_emitter = b.addExecutable(
        .{
            .name = "kosmos-consumer-input",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("test/native_consumer/emit.zig"),
                    .target = b.graph.host,
                    .optimize = host_modules.host_mode,
                    .imports = &.{.{ .name = "horos", .module = host_modules.horos }},
                },
            ),
        },
    );
    const native_input = b.addRunArtifact(native_input_emitter);
    b.step(
        "emit-native-input",
        "Emit the shared native public-consumer input",
    ).dependOn(&b.addInstallFileWithDir(
        native_input.captureStdOut(.{}),
        .prefix,
        "native-consumer.bpi3",
    ).step);

    return .{ .fixture = fixture, .current_fixtures = current_fixtures };
}

const ForeignChecks = struct {
    current_package_check: *std.Build.Step.Run,
    current_check: *std.Build.Step.Run,
};

fn configureForeignChecks(
    b: *std.Build,
    kernel: Kernel,
    packages: Packages,
    fixtures: Fixtures,
) ForeignChecks {
    const current_package_check = b.addSystemCommand(&.{"node"});
    current_package_check.addFileArg2(b.path("test/current/package.mjs"), .{});
    current_package_check.addDirectoryArg2(
        b.graph.path(.install_prefix, "runtime"),
        .{ .make_absolute = true },
    );
    current_package_check.addFileArg2(fixtures.fixture.getEmittedBin(), .{ .make_absolute = true });
    current_package_check.addFileArg2(
        b.graph.path(.install_prefix, "kernel-profile.json"),
        .{ .make_absolute = true },
    );
    current_package_check.addDirectoryArg2(
        b.graph.path(.install_prefix, "qualified-runtime"),
        .{ .make_absolute = true },
    );
    current_package_check.step.dependOn(packages.runtime_package);
    current_package_check.step.dependOn(&fixtures.current_fixtures.step);
    current_package_check.has_side_effects = true;
    b.step("check-package", "Run the current API and CLI from an extracted package")
        .dependOn(&current_package_check.step);
    const current_check = b.addSystemCommand(&.{"node"});
    current_check.addFileArg2(b.path("test/current/kernel.mjs"), .{});
    current_check.addFileArg2(kernel.current_kernel.getEmittedBin(), .{});
    current_check.addFileArg2(fixtures.fixture.getEmittedBin(), .{ .make_absolute = true });
    current_check.step.dependOn(&fixtures.current_fixtures.step);
    current_check.has_side_effects = true;
    b.step(
        "check-kernel",
        "Check ABI 3 and current native/Node transfer",
    ).dependOn(&current_check.step);

    return .{ .current_package_check = current_package_check, .current_check = current_check };
}

const SourceChecks = struct {
    source_agreement: *std.Build.Step.Run,
};

fn configureSourceChecks(
    b: *std.Build,
    options: Options,
    dependencies: Dependencies,
    kernel: Kernel,
    fixtures: Fixtures,
) SourceChecks {
    const source_examples = b.addRunFile(.zig_exe);
    source_examples.addArg("build");
    source_examples.addDirectoryArg2(.zig_lib, .{ .prefix = "--zig-lib=", .make_absolute = true });
    source_examples.addArgs(&.{ "emit-examples", "--build-file" });
    source_examples.addFileArg2(dependencies.source.path(b, "build.zig"), .{});
    source_examples.addArgs(&.{ b.fmt("-Doptimize={s}", .{options.profile.hostMode}), "--prefix" });
    source_examples.addDirectoryArg2(
        b.graph.path(.install_prefix, "source"),
        .{ .make_absolute = true },
    );
    source_examples.addArg("--cache-dir");
    source_examples.addDirectoryArg2(
        std.Build.LazyPath.cache_root.path(b, "source-examples"),
        .{ .make_absolute = true },
    );
    source_examples.has_side_effects = true;
    source_examples.expectExitCode(0);
    const source_agreement = b.addSystemCommand(&.{"node"});
    source_agreement.addFileArg2(b.path("test/current/source_agreement.mjs"), .{});
    source_agreement.addFileArg2(kernel.current_kernel.getEmittedBin(), .{});
    source_agreement.addFileArg2(fixtures.fixture.getEmittedBin(), .{ .make_absolute = true });
    source_agreement.addDirectoryArg2(
        b.graph.path(.install_prefix, "source"),
        .{ .make_absolute = true },
    );
    source_agreement.addFileArg2(
        dependencies.source.path(b, "test/v2/source_oracle.mjs"),
        .{ .make_absolute = true },
    );
    if (options.source_group) |group|
        source_agreement.addArg(@tagName(group));
    source_agreement.step.dependOn(&source_examples.step);
    source_agreement.step.dependOn(&fixtures.current_fixtures.step);
    source_agreement.has_side_effects = true;
    source_agreement.expectExitCode(0);
    const source_report = b.addSystemCommand(&.{"cat"});
    source_report.addFileArg2(source_examples.captureStdOut(.{}), .{});
    source_report.addFileArg2(source_agreement.captureStdOut(.{}), .{});
    source_report.has_side_effects = true;
    b.step(
        "check-source",
        "Compare current native/WASM execution with independent source semantics",
    )
        .dependOn(&source_report.step);

    return .{ .source_agreement = source_report };
}

const PortableChecks = struct {
    capacity: *std.Build.Step.Run,
    current_browser: *std.Build.Step.Run,
    current_codecs: *std.Build.Step.Run,
};

fn configurePortableChecks(b: *std.Build, kernel: Kernel, fixtures: Fixtures) PortableChecks {
    const capacity = b.addSystemCommand(&.{"node"});
    capacity.addFileArg2(b.path("test/current/capacity.mjs"), .{});
    capacity.addFileArg2(kernel.current_kernel.getEmittedBin(), .{});
    capacity.addFileArg2(fixtures.fixture.getEmittedBin(), .{ .make_absolute = true });
    capacity.step.dependOn(&fixtures.current_fixtures.step);
    capacity.has_side_effects = true;
    b.step(
        "check-capacity",
        "Check all current arena limits, physical memory and unchanged retries",
    )
        .dependOn(&capacity.step);
    const current_browser = b.addSystemCommand(&.{"node"});
    current_browser.addFileArg2(b.path("test/current/browser.mjs"), .{});
    current_browser.addFileArg2(kernel.current_kernel.getEmittedBin(), .{});
    current_browser.addFileArg2(fixtures.fixture.getEmittedBin(), .{ .make_absolute = true });
    current_browser.step.dependOn(&fixtures.current_fixtures.step);
    current_browser.has_side_effects = true;
    b.step(
        "check-browser",
        "Check real browser Worker/native transfer on Chromium and Firefox",
    ).dependOn(&current_browser.step);
    const current_codecs = b.addSystemCommand(&.{ "node", "--test" });
    current_codecs.addFileArg2(b.path("test/current/codec.test.mjs"), .{});
    current_codecs.addFileArg2(b.path("test/current/byte_contracts.test.mjs"), .{});
    current_codecs.addFileArg2(b.path("test/current/wasm.test.mjs"), .{});
    current_codecs.addFileArg2(b.path("test/current/file_input.test.mjs"), .{});
    current_codecs.addFileArg2(b.path("test/current/runtime_bundle.test.mjs"), .{});
    current_codecs.has_side_effects = true;
    b.step(
        "check-codecs",
        "Check current browser-neutral byte ownership and value contracts",
    ).dependOn(&current_codecs.step);

    return .{
        .capacity = capacity,
        .current_browser = current_browser,
        .current_codecs = current_codecs,
    };
}

const Activation = struct {
    activation_wasm_run: *std.Build.Step.Run,
};

fn configureActivation(b: *std.Build, wasm_modules: WasmModules) Activation {
    const activation_wasm_store = b.createModule(.{
        .root_source_file = b.path("src/interpreter_v2/activation_slots.zig"),
        .target = wasm_modules.wasm_target,
        .optimize = .safe,
        .imports = &.{.{ .name = "horos_data", .module = wasm_modules.wasm_data }},
    });
    const activation_wasm = b.addExecutable(
        .{
            .name = "activation-storage-test",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("test/v2/activation_storage_wasm.zig"),
                    .target = wasm_modules.wasm_target,
                    .optimize = .safe,
                    .imports = &.{.{ .name = "activation_slots", .module = activation_wasm_store }},
                },
            ),
        },
    );
    activation_wasm.entry = .disabled;
    activation_wasm.rdynamic = true;
    activation_wasm.export_memory = true;
    activation_wasm.stack_size = 65536;
    activation_wasm.max_memory = 4 << 20;
    const activation_wasm_run = b.addSystemCommand(&.{"node"});
    activation_wasm_run.has_side_effects = true;
    activation_wasm_run.addFileArg2(b.path("test/v2/activation_storage_wasm.mjs"), .{});
    activation_wasm_run.addFileArg2(activation_wasm.getEmittedBin(), .{});
    b.step("check-activation-storage-wasm", "Check storage on import-free unshared wasm32")
        .dependOn(&activation_wasm_run.step);

    return .{ .activation_wasm_run = activation_wasm_run };
}

fn configureQualification(
    b: *std.Build,
    dependencies: Dependencies,
    driver: Driver,
    foreign_checks: ForeignChecks,
    source_checks: SourceChecks,
    portable_checks: PortableChecks,
    activation: Activation,
) void {
    const check = b.step("check", "Check current native, host, portable and package contracts");
    const zig17 = b.step(
        "check-zig17",
        "Check pointer-borrow diagnostics and qualified storage ownership",
    );
    const borrow_probe = b.addExecutable(.{
        .name = "kosmos-borrow-diagnostics",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/interpreter_v2/borrow_diagnostics.zig"),
            .target = b.graph.host,
            // Keep the named assertion frame in intentional-panic diagnostics.
            .optimize = .debug,
            .imports = &.{.{ .name = "horos_data", .module = dependencies.host_data }},
        }),
    });
    const borrow_check = b.addRunArtifact(borrow_probe);
    b.step("build-zig17-check", "Build the pointer-borrow diagnostic artifact")
        .dependOn(&borrow_probe.step);
    borrow_check.has_side_effects = true;
    borrow_check.addArg("check");
    borrow_check.addArtifactArg2(borrow_probe, .{ .make_absolute = true });
    zig17.dependOn(&borrow_check.step);
    check.dependOn(zig17);
    check.dependOn(driver.native_checks);
    check.dependOn(&activation.activation_wasm_run.step);
    check.dependOn(&foreign_checks.current_check.step);
    check.dependOn(&source_checks.source_agreement.step);
    check.dependOn(&portable_checks.capacity.step);
    check.dependOn(&portable_checks.current_browser.step);
    check.dependOn(&portable_checks.current_codecs.step);
    check.dependOn(&foreign_checks.current_package_check.step);
}

fn configureReleaseTools(b: *std.Build) void {
    const module = b.createModule(.{
        .root_source_file = b.path("tools/release_refresh.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    const executable = b.addExecutable(.{ .name = "kosmos-refresh", .root_module = module });
    b.step("build-release-tools", "Build native frozen-source dependency preparation")
        .dependOn(&b.addInstallArtifact(executable, .{}).step);
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    run_tests.has_side_effects = true;
    b.step("check-release-tools", "Check native source admission and semantic preparation")
        .dependOn(&run_tests.step);
    const coherence = b.addRunArtifact(executable);
    coherence.addArg("check");
    coherence.addFileArg2(.zig_exe, .{ .make_absolute = true });
    coherence.addDirectoryArg2(b.path(""), .{ .make_absolute = true });
    coherence.has_side_effects = true;
    b.step("check-release-coherence", "Check local version and generated-source coherence")
        .dependOn(&coherence.step);
    configureReleaseSource(b, executable);
}

fn configureReleaseSource(b: *std.Build, executable: *std.Build.Step.Compile) void {
    const revision = b.addSystemCommand(&.{ "git", "--no-replace-objects", "rev-parse", "HEAD" });
    revision.setCwd(b.path(""));
    revision.has_side_effects = true;
    const prepare = b.addRunArtifact(executable);
    prepare.addArg("source-build");
    prepare.addFileArg2(.zig_exe, .{ .make_absolute = true });
    prepare.addDirectoryArg2(b.path(""), .{ .make_absolute = true });
    const output = prepare.addOutputDirectoryArg2("release-source", .{ .make_absolute = true });
    prepare.addFileContentArg2(revision.captureStdOut(.{}), .{});
    prepare.has_side_effects = true;
    b.step("check-source-package", "Consume the independently authenticated native source archive")
        .dependOn(&prepare.step);
    b.step("release-source", "Retain the verified full-source archive and package inventory")
        .dependOn(&b.addInstallDirectory(.{
        .source_dir = output,
        .install_dir = .prefix,
        .install_subdir = "release-source",
    }).step);
}
