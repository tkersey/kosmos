# Kosmos 9

Formerly World; see the [rename notes](docs/rename.md).

Kosmos executes complete Horos programs through a Horos-authored semantic core
on a first-order native or import-free wasm32 base. Computations, handlers,
retained control and cleanup are program data. The environment supplies typed
external results. See [executable semantics](docs/executable-semantics.md) for
the runtime artifacts, specialization, reconstruction, and trusted boundaries.

Kosmos `9.1.0` requires exact Zig `0.17.0`; source builds use Horos 7.
It consumes BPI3 programs and PST3 states through ABI 3. See the
[ABI contract](docs/kernel-abi.md) and [verification boundaries](docs/verification.md).
Current source/package identities are selected by the consuming lock; published
release bytes remain unchanged.

## JavaScript and browser Workers

The package root is an environment-neutral byte API:

```js
import { Kernel, encodeInput, decodeOutcome, decodeRequest, encodeResult } from "@tkersey/kosmos";
const kernel = await Kernel.create({ bytes: kernelBytes, expectedSha256 });
const outcome = decodeOutcome(kernel.invoke(encodeInput({ image, initialArgs })));
if (outcome.kind === "requested") {
  const request = await decodeRequest(outcome.request);
  // Resolve the declared operation using the environment's permitted adapter.
  const value = await encodeResult(outcome.request, typedReplyBytes);
  const next = decodeOutcome(kernel.invoke(encodeInput({ image, state: outcome.state, control: "reply", value })));
}
```

Supply expected kernel identity from the consuming application's trusted binding.
The same entry point loads directly in a real browser Worker without Node imports
or a bundler. Inputs and returned buffers have explicit ownership; old image,
checkpoint and envelope families reject.

`prepare`, `start`/`restore`, `drive`, `checkpoint`, `close`, and
`releasePrepared` expose prepared/resident execution through the same evaluator.
Resident checkpoints are explicit; `checkpoint(session, { transfer: true })`
exports and releases only after successful output publication. `close` requires
terminal control. Cancellation and cleanup are executable operations, not physical
handle destruction. Use `setLimits` to select input, working and output budgets.

Native consumers import `kosmos.Session`, `kosmos.Prepared`, `kosmos.Resident`, and
`kosmos.invocation`. Execution admits ordinary bytes through Horos's data
module. Build-time artifact generation uses Horos authoring and specialization.

`Resident.publish(destination, control, options)` is the native publication
transaction. Destinations select a record, encoded bytes, or a caller buffer.
Checkpoint mode `.none` streams the pending-state digest without allocating
checkpoint output; `.inline_state` preserves existing PKO3 state fields;
`.receipt` returns a separate owning `Checkpoint`, including terminal states.
The outcome and receipt are produced before the same commit fence. Existing
`drive`, `driveEncoded`, and `driveInto` delegate to it.

Move a receipt out with `Publication.takeCheckpoint()` before destroying its
publication. Its bytes are immutable and remain caller-owned after
`Resident.transferCheckpoint(receipt)`. Transfer checks the exact issuer and
committed generation, then retires the Resident without another serialization.
Successful drives stale earlier receipts; failed drives preserve them. Ordinary
checkpoint inspection does not change generation. `takeCheckpoint` remains the
fresh-snapshot fallback, and `close` remains terminal-only. A receipt retains
one complete checkpoint buffer plus its small owner and shared identity cell.
Receipts use the Resident's allocator, which must outlive them; temporary
outcome allocators can be released independently. A receipt establishes local custody only, not durable
storage commit or exclusive execution of copied snapshots.

## Build, package and command line

```sh
zig build build-kernel build-runtime
node zig-out/runtime/bin/kosmos.mjs --help
node zig-out/runtime/bin/kosmos.mjs invoke --kernel zig-out/runtime/kosmos-kernel.wasm --sha256 EXPECTED_SHA256 --input command.pki3 > outcome.pko3
```

The CLI reads regular files, rejects observed changes, and writes canonical PKO3
bytes to stdout. The input is a complete PKI3 command, including image, initial
arguments or checkpoint, reply/cancellation/yield control, and optional quantum.
`build-runtime` creates a standalone package under `zig-out/runtime` without
constructing Horos's authoring compiler. It does not publish a package.

```sh
zig build check
```

Native consumers use the public `kosmos` module and the package selected by
`build.zig.zon`. An explicit `-Dhoros-source=/absolute/source` override is
captured by Zig and admitted against the selected package hash; the native build
uses `tar` to unpack that authenticated snapshot for compilation. No interpreter,
JS/WASM archive or script-generated metadata is a native prerequisite.

`check-native` and `check-storage` use shared native build roots. `check-source`
compares 44 source examples with the independent higher-order oracle and actual
native/WASM execution. The optional JS checks cover canonical bytes, handles,
capacity/retry behavior, package/CLI consumption and real Chromium and Firefox Workers.
Repeated measurement/transfer campaigns and the Python/Wasmtime dependency are
retired. The old `runtime prepare` producer is replaced by the ordinary Zig
package build and existing qualification roots.

## State and effects

BPI3 contains the closed executable Program; PST3 contains complete portable
execution. Fresh and resident operations publish only after admission and output
encoding succeed. Physical failures leave the prior authoritative input reusable.
Quanta bound internal transitions without changing authored results or effect order.
An unbounded invocation may diverge if the authored program diverges.

A cancelled pending cleanup retains its control and receives a newly bound request.
The environment may re-encode an already acquired typed result against that request;
Kosmos does not provide external rollback or global exactly-once effects.

Stable delivery and its compatibility limits are described in
[runtime bundles](docs/runtime-bundles.md). Protean applications retain their own
migration and qualification requirements.

See [verification](docs/verification.md) for the current coverage and the
remaining migration boundaries.

New and materially changed Zig code follows [TigerStyle for Kosmos](https://github.com/tkersey/kosmos/blob/main/docs/tiger-style.md).
Run its committed-change ratchet alongside the affected qualification roots.

Source builds and existing v1 authenticated acquisition/verification are documented in [runtime bundles](docs/runtime-bundles.md).
