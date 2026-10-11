# Source packages and historical runtime bundles

Kosmos has one Zig evaluator. Its current native import/build path uses the
Horos package selected by `build.zig.zon`; it does not acquire a JS/WASM
runtime bundle or run a foreign-language preparatory command.

## Build the optional JavaScript package

```sh
zig build build-runtime -Doptimize=safe
node zig-out/runtime/bin/kosmos.mjs --help
```

The Zig build owns kernel construction, resolved build metadata and package
assembly. The existing `check` roots qualify those same artifacts, including
source agreement, kernel identity/ABI, ownership, memory and browser Worker
observations. The ordinary source-built package is not labeled a v1 qualified
runtime bundle. The explicit `package.json` file list owns both Zig assembly and npm packaging,
so stale files in a reused output directory cannot enter the new package. To
create the ordinary npm archive, run `npm pack --offline --ignore-scripts` in
`zig-out/runtime`. CI retains this tested npm archive as its workflow artifact;
release publication remains a separate authorized operation.

The old `runtime prepare` interface and its script-based source/package/compiler
orchestration and repeated delivery campaigns are retired. Use `build-runtime`
and the existing checks directly. Historical qualification and performance
collectors remain in Git history rather than a dormant producer stack.

## Consume an existing v1 delivery

The acquisition and verification interfaces for published v1 bundles remain:

```sh
node bin/kosmos.mjs runtime acquire --archive bundle.tar.gz \
  --archive-sha256 APPROVED_ARCHIVE_SHA256 \
  --manifest-sha256 APPROVED_MANIFEST_SHA256 --output NEW_DIRECTORY
node bin/kosmos.mjs runtime verify --root NEW_DIRECTORY \
  --manifest-sha256 APPROVED_MANIFEST_SHA256 --smoke
```

The external digest is required. Acquisition authenticates the archive before
extracting safe bounded files and rejects output collisions. Verification binds
complete file inventory, modes, source/dependency/toolchain records, actual
kernel identity and ABI/memory profile, and the required recorded qualification.
Smoke checks execute a private verified snapshot, not a mutable source path.

`src/node/runtime-profile.json` is the immutable admission policy for the existing
World 6.0.0 v1 format. It deliberately retains that release's original Boundary
source/package identity. Current native build settings live in `build-profile.json`
and the current package dependency lives in `build.zig.zon`; updating them does
not reinterpret an old delivery or authorize changing a published asset.

Boundary 3.0.0 / World 6.0.0 release bytes, tags and delivery descriptors remain
unchanged. Existing consumers may keep their pinned artifacts. This change does
not migrate saved state, provide hot upgrades, or add distributed custody.
