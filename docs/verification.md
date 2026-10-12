# Verification boundaries

The native roots preserve the evaluator and language contracts:

- `check-storage`: the existing native interpreter/storage/allocation root.
- `check-native`: shared native source/session/restore checks and storage tests.
- `check-zig17`: native subprocess checks of actual activation-view borrow
  invalidation, including expected assertion failures and leak-free valid paths.

These roots use Zig’s authenticated package cache and the ordinary `tar`
utility. An explicit Horos source override must produce the selected package
hash; modules and emitters then consume that captured package, so later edits to
the supplied directory cannot change the compiled input. They do not need Node, Python, a WASM bundle or a package producer.

The optional foreign-environment roots have distinct consumers:

- `check-source`: the independent Horos higher-order interpreter versus actual
  compiled native/WASM execution, preserving all 42 source examples.
- `check-kernel`: the real JS embedding and canonical native/WASM ABI observations.
- `check-capacity`: guest buffer bounds, physical memory growth and unchanged retry
  input; the fixed-memory case changes only the real module's memory declaration.
  Its existing large-request fixture now uses Horos 4 named functions and nested
  typed records. Independent expected payload/result bytes are unchanged and
  checked in both native and WASM execution. The production interpreter still
  imports only `horos_data`.
- `check-codecs`: JS byte/value ownership, cross-realm inputs, ABI admission,
  regular-file reads, and existing v1 bundle acquisition/verification.
- `check-browser`: an actual Chromium Worker → native → fresh Worker transfer,
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
node test/current/browser-tools/node_modules/playwright-core/cli.js install chromium
zig build check -Doptimize=safe
```

CI installs Chromium's Linux system dependencies with Playwright's `--with-deps`
option. Firefox and Python/Wasmtime are not part of the current checks.
