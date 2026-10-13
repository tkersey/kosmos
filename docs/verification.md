# Verification boundaries

The native roots preserve the evaluator and language contracts:

- `check-storage`: the existing native interpreter/storage/allocation root.
- `check-native`: shared native source/session/restore checks and storage tests.
- `check-publication`: the public-module subset for predecessor large-state
  recovery, typed/encoded native invocation, explicit finite decoder budgets,
  receipt generations and issuers, and publication/restore allocation failures.
- `check-zig17`: native subprocess checks of actual activation-view borrow
  invalidation, including expected assertion failures and leak-free valid paths.

These roots use Zig’s authenticated package cache and the ordinary `tar`
utility. An explicit Horos source override must produce the selected package
hash; modules and emitters then consume that captured package, so later edits to
the supplied directory cannot change the compiled input. They do not need Node, Python, a WASM bundle or a package producer.

The native recovery test retains the exact 52-byte predecessor BPI3 and the
three original PST3 hashes in `test/v2/native_decode.zig`. Large states are
generated sequentially. The below-64-MiB checkpoint is a distinct assertion:
owned input plus expanded records exceeded the former default. Caller-selected
finite budgets still reject it. Native defaults use the caller's allocator and
representable sizes; this does not expand the JS/WASM physical input domain.

The optional foreign-environment roots have distinct consumers:

- `check-source`: the independent Horos higher-order interpreter versus actual
  compiled native/WASM execution, preserving all 42 source examples.
- `check-kernel`: the real JS embedding and canonical native/WASM ABI observations.
- `check-capacity`: guest buffer bounds, physical memory growth and unchanged retry
  input; the fixed-memory case changes only the real module's memory declaration.
  Its existing large-request fixture uses Horos named functions and nested
  typed records. Independent expected payload/result bytes are unchanged and
  checked in both native and WASM execution. The production interpreter still
  imports only `horos_data`.
- `check-codecs`: JS byte/value ownership, cross-realm inputs, ABI admission,
  regular-file reads, and existing v1 bundle acquisition/verification.
- `check-browser`: actual Chromium and Firefox Worker → native → fresh Worker transfers,
  including retained scoped computations and explicit handle cleanup.
- `check-package`: the extracted npm consumer and small public CLI, not source imports.

`check` composes these existing roots. Node/browser dependencies stop at these
explicit checks and the optional JS consumer. Native and source-dependent checks
share a build graph; no per-feature wrapper rebuilds the authoring machinery.

Historical Python/Wasmtime transfer, timing, layout, replay, scalar/blob/history
measurement and duplicate platform campaigns are retired with their exclusive
emitters and locks. Sampler-only assertions are removed with their collectors.
The evaluator, memory/ownership guards, independent expectations and public JS
interface remain. Prior release results do not qualify a successor; PR summaries
record actual subjects, executed checks and remaining limits.

## Run the checks

From a source checkout, native checks use the pinned Zig toolchain, `tar`, and
the source dependency:

```sh
zig build check-native check-zig17 -Doptimize=safe
```

For the optional JavaScript and browser checks, install their locked tooling:

```sh
npm ci --ignore-scripts --prefix test/current/browser-tools
node test/current/browser-tools/node_modules/playwright-core/cli.js install chromium firefox
zig build check -Doptimize=safe
```

CI installs both browsers' Linux system dependencies with Playwright's
`--with-deps` option. Python/Wasmtime is not part of the current checks.
