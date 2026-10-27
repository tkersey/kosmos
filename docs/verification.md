# Verification boundaries

[TigerStyle](https://github.com/tkersey/kosmos/blob/main/docs/tiger-style.md) adds a concurrent development-source gate. Its native
auditor self-tests and committed-change ratchet must pass along with all existing
runtime qualification lanes. `Complete qualification` requires both results.
Runtime qualification retains its 600-second workflow budget; TigerStyle is
exempt from that budget and has an independent 10-minute job timeout.

The native roots preserve the evaluator and language contracts:

- `check-storage`: current base storage and allocation contracts.
- `check-native`: shared native source/session/restore checks and storage tests.
- `check-publication`: the public-module subset for predecessor large-state
  recovery, typed/encoded native invocation, explicit finite decoder budgets,
  receipt generations and issuers, and publication/restore allocation failures.
  It also rejects insufficient caller capture bounds during implicit disposal
  and restores valid failure, fault and cancellation cleanup through direct,
  nested and closure calls, injected computations, nested captured tokens and
  deep and shallow nested same-family handlers. Explicit disposal, ordinary resume and successor
  resume preserve cleanup; restored and uninterrupted terminal bytes agree.
  Owned answers returned by cleanup during explicit disposal are themselves
  disposed, including across checkpoint restoration and cancellation. Encoded
  publication accepts an exact final-byte output budget; staging uses the
  resident allocator, and insufficient output capacity preserves retry state.
- `check-zig17`: native subprocess checks of actual activation-view borrow
  invalidation, including expected assertion failures and leak-free valid paths.

The aggregate `check` includes the entire `check-native` root, including
`check-publication`.

The semantic suites share setup in `src/semantic/test_support.zig`, which has
no test declarations. Each suite retains its own cases and expected results.
Behavioral, lifecycle, custody and restore regressions in `stable_source.zig`,
`source_regressions.zig` and the public publication suite run against the new
public semantic runtime. Guest-state assertions inspect canonical checkpoints;
physical storage assertions target storage still used by the current base.
Retired native cache layouts, frame-handle identities, flow arenas and native
optimization counters are not requirements of the new evaluator.
Storage-owner and base-transaction tests exhaust native allocation sites, including
rollback and retry across complete recursive execution. Public sweeps separately
cover owned unwind and acquired reply/transaction/publication ownership. Actual
clone, shallow resume, cleanup, cancellation and reentry fixtures each fail the
final encoded publication before commit, in both checkpoint modes, then require
unchanged state and exact retry. Their algorithms execute as ordinary data
programs over the same native owners; each does not require another exhaustive
sweep of those owners through the full evaluator.
Suspension reclamation exhausts rollback/retry with an eight-element encoded
sequence, and retains the original 8192-element fixture at the final publication
fence in both checkpoint modes. The independent 131072-element fixture preserves
the live/dead backing bounds, aliases, canonical restore and continuation checks.
Full-program result, effect-order and checkpoint fixtures remain separate from
those failure sweeps; former native optimizer paths do not each require replaying
the generic evaluator's complete allocation history.

The build fetches the hash-pinned Kosmos `62279bce8e916e7fe613fe4575b3bc12e530596f`
archive only as the independent evaluator for differential comparisons and
benchmarks. Both use the selected Horos admission/codec module; the historical
guest evaluator and its storage/lifecycle code are immutable. The build does not
import the historical test root. Passing reference-engine tests would not qualify
the new engine. The table witnesses build one image for both evaluators and retain both execution
paths, all boundary inputs and restore assertions.

Qualification separates immutable preparation from mutable lifecycle checks.
The deep-session and PST3 restore allocation sweeps reuse an admitted `Prepared`
owner while exhausting every allocation of the session operation. Guest
preparation separately sweeps the full 64-field contract fixture. Artifact
admission sweeps bundle decoding, the bridge program, all four helper owners,
canonical encoding and the final shared core using small admitted programs;
the complete evaluator still has exact source/packaged-byte and differential
qualification. One full fresh-invocation sweep retains its output/input atomicity
assertions. These are complementary ownership boundaries, not cached test results.

Instruction-by-instruction lifecycle comparisons share immutable preparation
and reconstruct fresh mutable sessions at every cut. The reconstructed invocation
also supplies the restoration comparison: `advance(.none)` directly calls
`Session.run`, so a second restored execution would repeat that same transition.
The independent direct session and transactional resident remain compared at
every cut, after their input checkpoint buffer is overwritten. Source agreement likewise
keeps a native peer process and one WASM prepared handle, restores every PST3,
and alternates the actual native/WASM state producer. It retains all 47 prior examples,
every prior quantum-one observation, cancellation frontier, independent source result,
effect trace and canonical-byte assertion. The separate kernel suite still
exercises the complete fresh invocation entry point alongside resident execution.
The long recursion resource fixture retains all 10,000 calls and its node bound
at every 31-step cut. It compares framing once, then executes each remaining
slice once while retaining canonical checkpoint checks at every cut.
The indirect recursion fixture retains inputs 7, 127 and 1024, both tail and
non-tail calls, every 13-step cut and every seventh-cut restoration. Tail-space
checks still export at every cut. The intentionally growing non-tail control
exports only at those restoration points; its other exported bytes were unused.

These roots use Zig’s authenticated package cache and the ordinary `tar`
utility. The immutable baseline fetch rechecks the global package cache even
when a local build cache survives, so an evicted archive is restored before use.
An explicit Horos source override must produce the selected package
hash; modules and emitters then consume that captured package, so later edits to
the supplied directory cannot change the compiled input. They do not need Node, Python, a WASM bundle or a package producer.

Native semantic qualification rebuilds the evaluator from authored source. An extracted
native package consumer uses the shipped ordinary artifact after checking its
source, compiler and content fingerprints; it does not rebuild the host generator
or run unrelated suites. Both paths perform the same runtime artifact admission.

The native recovery test retains the exact 52-byte predecessor BPI3 and the
three original PST3 hashes in `test/v2/native_decode.zig`. Large states are
generated sequentially. The below-64-MiB checkpoint is a distinct assertion:
owned input plus expanded records exceeded the former default. Caller-selected
finite budgets still reject it. Native defaults use the caller's allocator and
representable sizes; this does not expand the JS/WASM physical input domain.

The optional foreign-environment roots have distinct consumers:

- `check-source`: the independent Horos higher-order interpreter versus actual
  compiled native/WASM execution for 70 source examples, including all 42
  historical examples and 23 typed hyperfunction fixtures. Captured Need cases
  exercise distinct entry arguments, completion effects, repeated requests and
  disposal, and a completion using a cell allocated inside its task through
  resident execution and every restored quantum-one cut.
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

The source comparison overlaps the independent native child and WASM execution
for each identical immutable command. It awaits both before the next observation,
retaining every restore, transfer checkpoint, byte comparison and source assertion.

CI runs session behavior, session ownership/failure, source regression, native
semantic, specialization/publication, two source-agreement and portable groups independently; their union is
exactly the aggregate `check` dependency set. The session partitions retain all
86 named cases (54 behavior, 16 ownership/failure, 16 source regressions) and
the anonymous import sentinel. Standalone test executables show each case and
require the complete selected count; the ordinary `check-sessions` target still
runs all 87 cases together. Source-agreement partitions select disjoint fixture
sets while retaining every mode, instruction frontier, cancellation and comparison;
together they execute all 70 fixtures and report their actual observation counts. The native semantic
group rebuilds the source artifact, while specialization and publication use the
same authenticated packaged artifact. It does not invoke `check-native` and then the
overlapping `check`. Native test run steps always execute, even when compilation
is cached. An independent native-consumer lane builds only its Horos-authored
input producer and the extracted public package, without compiling the optional
ABI fixture peer. Compiler caches may reuse content across dependency-lock changes;
Zig's input hashes and the dependency admission guards remain authoritative.
The native lane compiles its existing test artifacts and independently rebuilt
core before retaining the bounded compiler cache. It then executes the original
check roots, so a later test timeout does not discard completed compilation.
The Zig installation uses a stable tool-cache path because dependency extraction
includes `PATH` in its input identity. Neither cache restoration nor successful
compilation substitutes for completed tests.
The other lanes use `-Dpackaged-runtime=true` to authenticate the exact shipped
artifact whose source correspondence the native semantic lane checks. All lanes
retain full runtime artifact and guest-state admission.
Matching compiler artifacts are restored and missing inputs are rebuilt; every
selected test still executes. Every runtime lane has at most ten minutes. The runtime
budget gate checks elapsed time from workflow start against 600 seconds without
waiting for TigerStyle. The terminal gate requires both the bounded runtime
qualification and the exempt TigerStyle job to succeed.
The pinned Zig setup action uses `zigmirror.com`, selected from measured Linux
acquisition times in the integrated Protean qualification. Upstream signature and
archive-name verification remain active. An explicit mirror removes the action's
randomized selection and automatic fallback; future availability is not guaranteed.

Historical Python/Wasmtime transfer, timing, layout, replay, scalar/blob/history
measurement and duplicate platform campaigns are retired with their exclusive
emitters and locks. Sampler-only assertions are removed with their collectors.
The evaluator, memory/ownership guards, independent expectations and public JS
interface remain. Prior release results do not qualify a successor; PR summaries
record actual subjects, executed checks and remaining limits.

## Run the checks

The adaptive-authoring consolidation selects Horos 8's canonical ordinary
library surface. Deliberate cleanup fixtures now use
`horos.source.library.cleanup`; no evaluator or portable-state family changes
are needed. The session behavior suite imports Horos's ordinary package client
from the authenticated package snapshot. It executes the Search callable and
nested bounded record retained across Reader's scoped operation, then checks
the independently specified result 42. This complements Horos's exported-client
shape assertions and image-admission check with actual Kosmos execution.

The selected dependency and regenerated packaged evaluator must be qualified
together. Source overrides still have to produce the exact `build.zig.zon`
package hash. Neither a version match nor an earlier prerequisite run qualifies
the consolidation candidate. Saved tasks retain their existing program/runtime
binding; rollback restores the previous complete tuple rather than combining
the old packaged evaluator with a new dependency manifest.

The rebuilt consolidation evaluator bundle is 275,293 bytes, unchanged in size
from the qualified prerequisite. Comparing its complete bytes with that bundle
after replacing only the embedded Horos package identifier yields equality.
The new artifact SHA-256 is
`b3c148f348a579cb5456a6bf6f5fdedf44a9e2a3a5d664eade1f51fcc28e11fa`.
This establishes unchanged evaluator-image content for these two builds; it
does not make arbitrary saved-task bindings interchangeable. Final execution
qualification remains a separate requirement.

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

## Native publication measurements

`zig build bench-publication -Doptimize=safe` writes
`zig-out/publication.jsonl`. It accepts the same authenticated `-Dhoros-source`
override as the native checks. This optional diagnostic is outside `check` and
sets no timing threshold. Host optimization follows `build-profile.json` (`safe`).

The measured core is Kosmos `863af1ff776273cfa0d3e73ce72b58dceb36f3b1`
with Horos `f04359ca8b958a07d1bcc14748e35adfacd3ffed`, plus the benchmark
sources in this revision. Platform: Apple M2 Pro, macOS 27.2 (26B5101f), Zig
0.17.0. The yield fixture uses the exact 52-byte historical program. The request
fixture retains the same bytes across one external unit request. Both must
restore and finish with the original encoded argument. Every sample checks exact
receipt/snapshot equality, one publication projection, zero transfer projections,
and complete release of measured owner allocations.

Times are microseconds, medians after the first observation. Each repetition
prepares and starts fresh owners. Raw JSONL retains every observation and hash.
Input construction, output formatting, result verification and final cleanup
are outside timed regions. Transfer time includes retiring the resident.

| Fixture/payload | Repetitions | Prepare | Start | Publish with receipt | Snapshot | Transfer receipt | Restore |
|---|---:|---:|---:|---:|---:|---:|---:|
| yield/64 B | 10 | 2.4 | 0.9 | 3.0 | 0.7 | 0.4 | 2.3 |
| yield/1 MiB | 10 | 2.5 | 119.4 | 218.2 | 231.0 | 16.2 | 197.2 |
| yield/65 MiB | 4 | 12.1 | 9088.1 | 16661.2 | 16753.8 | 1568.3 | 13568.9 |
| request/64 B | 10 | 3.4 | 0.8 | 4.9 | 0.9 | 0.5 | 4.2 |
| request/1 MiB | 10 | 3.3 | 113.9 | 645.2 | 214.1 | 14.9 | 198.8 |
| request/65 MiB | 4 | 19.6 | 9117.7 | 45654.6 | 16426.0 | 1616.5 | 13595.6 |

The existing `AllocationBudget` wraps the process allocator with its representable
maximum limit; it counts requested bytes and does not support resize/remap.
Instrumentation affects these timings and allocation shapes. The following are
maximum observed live requested bytes, excluding allocator metadata, RSS, input
construction, and the separate Prepared owner. Resident and output peaks are
separate allocation domains and must not be added as a simultaneous peak.

| Fixture/payload | Checkpoint | Retained receipt | Publication resident peak | Publication output peak | Restore peak |
|---|---:|---:|---:|---:|---:|
| yield/64 B | 142 | 254 | 7436 | 22 | 4174 |
| yield/1 MiB | 1048658 | 1048770 | 3676772 | 22 | 1576212 |
| yield/65 MiB | 68157524 | 68157636 | 238557801 | 22 | 102239512 |
| request/64 B | 157 | 269 | 7317 | 3724 | 4726 |
| request/1 MiB | 1048673 | 1048785 | 3677044 | 3724 | 1576440 |
| request/65 MiB | 68157539 | 68157651 | 238558073 | 3724 | 102239738 |

Receipt storage belongs to the **resident allocator**, not the encoded-outcome
allocator. After transfer it retains the full checkpoint plus 112 bytes on this
target, including the issuer identity. That memory remains until receipt
deinitialization. Publication's live resident allocation before retirement is
also recorded in JSONL. A snapshot measurement retains the existing receipt while
creating a second byte copy; it is not the cost of a receipt-free resident.

Preparation retains 3,708 requested bytes for the yield program and 4,118 for
the request program (peaks 5,620 and 5,898). Those counts exclude live resident
and receipt owners. The 65 MiB cases have only four repeated observations and
support no tail-latency claim. Process-allocator reuse, power state and load affect
small timings. Snapshot and publication perform different work; their timings
are not a before/after comparison. These measurements establish local costs and
the serialization/memory tradeoff, not a product or provider speedup.

## Typed hyperfunction transfer

The source-agreement root consumes Horos's ordinary typed hyperfunction images
through the existing native and WASM evaluators. Its 23 fixtures cover ignored
peers and successor states, retained definitions, lazy data, nested nominal Need
families, task acquisition, repeated and adaptive requests, requester disposal,
captured step and completion values, task-local cells, and three distinct
composition endpoints. All 256 byte inputs check the
heterogeneous composition result; inputs 0, 7 and 255 also restore each instruction.

Task fixtures compare an uninterrupted resident with the independent source
oracle and native/WASM execution restored from portable states. Quantum-one cuts
include the first external request before successor demand and counterpart
returns with non-tail work still pending. Successful, overflowing and cancelled
executions retain exact effect, result, failure and cleanup observations.
Acquiring a task produces no task effects. Two adaptive reply sequences select
different numbers of counterpart requests. These finite observations establish
the exercised demand and transfer behavior, not termination of arbitrary
recursive programs.

The migration's coalescing images were also measured on an Apple M2 Pro with
Zig 0.17.0, native `safe`, WASM `small`, and Node 26.12.1. Baseline images came
from Horos `ae8ace5feecfda2e194b8ecad6fbe3a86ff91108`. The candidate snapshot's
source matches Horos `5bea02f41e6ca5cbc41f91ad7497f48742004557` except for its
package-version string. The image identities and authoring costs are recorded
in that candidate's `docs/recursive-interaction.md`.

| Fixture | Quantum-one invocations, baseline → candidate | WASM drive ms | Native invocation ms |
|---|---:|---:|---:|
| duplicate | 56 → 57 | 45.953 → 47.008 | 17.614 → 17.752 |
| configured | 58 → 59 | 49.090 → 48.279 | 18.510 → 18.749 |
| lazy | 26 → 27 | 19.221 → 20.899 | 8.346 → 9.057 |

All 283 quantum-one observations compared native/WASM bytes, alternating the
checkpoint producer. Inputs `(2,3)` produced `(12,13)`, `(12,14)` and `(2,3)`
respectively, matching the independent source oracle. Timing medians use twelve
batch means of sixteen executions after twenty-four warmups per image/backend;
baseline/candidate order alternates and every result is checked. WASM timing
excludes preparation, start and close. Native timing includes fresh sessions,
codecs, framing, IPC and Node scheduling. Concurrent qualification was running;
these local observations impose no timing gate or claim of isolated VM cost.

The measured WASM SHA-256 is
`91107599c58c85b115db4bed8b5181b4ace156887406f69629c55a793acc443f`;
the native fixture SHA-256 is
`92c4de2046dbb542b655d51284f9d75b774fbc855a8f58cf9ee67f7e0929a72b`.
Both use the source/compiler/content bindings in `src/semantic_packaged.zig`.

## Stateful service composition

The Horos paper witness uses the existing generator and protected region/cell
mechanisms. `stable_source.zig` runs empty, two-request, overflow, cancellation,
swapped-reply and two-instance scenarios both uninterrupted and restored at
yields. It checks request ids, prior counter values, final counters, finalizer
multiplicity and that a next command cannot enter before the prior reply. Two
equal-typed service instances exist concurrently and each returns prior zero.

A one-step native witness also checks the control positions used by Horos's
interaction projection: local perform enters its clause atomically, and yield
installs its successor before suspending. Restored checkpoints cancel successfully
at both positions. This distinguishes actual runtime prefixes from extra paths
introduced by a conservative analysis.

`source_agreement.mjs` compares actual native/WASM execution and canonical state
transfer with the independent authored-source oracle. For the single-service
fixtures it additionally checks that projected native traces belong to Horos's
implementation-checked finite interaction graph. The graph is optional test
output, never runtime admission or a new state format. Existing source fixtures
continue to discriminate shared aliases from distinct owners; existing publication
checks retain issuer/generation/consumed-receipt and allocation-failure guarantees.

These checks establish the exercised finite traces. Fair scheduling, arrival of
external outcomes and sufficient resources remain premises of completion. Legal
multi-shot continuations do not authorize duplicate external settlement.
