# Verification boundaries

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
and alternates the actual native/WASM state producer. It retains all 47 examples,
every quantum-one observation, cancellation frontier, independent source result,
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
utility. An explicit Horos source override must produce the selected package
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
  compiled native/WASM execution for 47 source examples, including all 42
  historical examples.
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

CI runs session, native semantic, source-agreement and portable groups independently;
their union is exactly the
aggregate `check` dependency set. It does not invoke `check-native` and then the
overlapping `check`. Native test run steps always execute, even when compilation
is cached. An independent native-consumer lane builds only its Horos-authored
input producer and the extracted public package, without compiling the optional
ABI fixture peer. Compiler caches may reuse content across dependency-lock changes;
Zig's input hashes and the dependency admission guards remain authoritative.
The other lanes use `-Dpackaged-runtime=true` to authenticate the exact shipped
artifact whose source correspondence the native semantic lane checks. All lanes
retain full runtime artifact and guest-state admission.
The workflow-dispatch `compiler-cache=false` input disables compiler restoration
for a cold measurement. Every job has at most ten minutes, and the terminal gate
also checks the elapsed time of the complete workflow against 600 seconds.

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
