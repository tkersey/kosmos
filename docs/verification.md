# Verification boundaries

[TigerStyle](https://github.com/tkersey/kosmos/blob/main/docs/tiger-style.md) adds a concurrent development-source gate. Its native
auditor self-tests and full-source audit of the committed candidate must pass
along with all existing runtime qualification lanes. `Complete qualification` requires both results.
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

CI distributes the aggregate `check` dependencies across session behavior,
session ownership/failure, source regression, native owners, ordinary and checked
drivers, ordinary and recovery specialization, publication, source agreement and
portable qualification. The session partitions retain all 90 named cases
(58 behavior, 16 ownership/failure and 16 source regressions) and the anonymous
import sentinel. Standalone test executables show each case and require the
complete selected count. The ordinary `check-sessions` target runs all 91 cases
together. Source-agreement partitions select disjoint fixture
sets while retaining every mode, instruction frontier, cancellation and comparison;
together they execute all 70 fixtures and report their actual observation counts. The native semantic
group rebuilds the source artifact, while specialization and publication use the
same authenticated packaged artifact. It does not invoke `check-native` and then the
overlapping `check`. Native test run steps always execute, even when compilation
is cached. An independent native-consumer lane builds only its Horos-authored
input producer and the extracted public package, without compiling the optional
ABI fixture peer. Compiler caches may reuse content across dependency-lock changes.
Cache lookup prefers the same lane and lock, then a related lane with the same lock,
then the same lane or its related lane across dependency-lock changes. Zig's input
hashes and the dependency admission guards remain authoritative; a cache hit never
replaces test execution.
Hosted lanes build host tools, the evaluator emitter and native tests for
`-Dhost-target=x86_64-linux.5.10...7.2-gnu.2.31`: the architecture, the Linux 5.10–7.2
range, the ABI and glibc 2.31, so nothing in it comes from the runner's kernel or C
library. Every qualification build passes the same target and CPU as `-Dtarget` and
`-Dcpu` too, so public modules and `zig-out` build for them and share the host modules.
Before restoring, each lane chooses `-Dhost-cpu` with
`tools/zig-cache.sh host-cpu`, which reads the runner's `/proc/cpuinfo` flags. It
selects `x86_64_v3+sha` only when they include `sha_ni` and every feature that Zig
0.17.1's `x86_64_v3` adds to the x86-64 baseline (`pni ssse3 sse4_1 sse4_2 popcnt cx16
lahf_lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave`), and `baseline` otherwise. No
binary therefore runs on a CPU that lacks its features: a runner without them builds
for `baseline` and misses the `x86_64_v3+sha` caches instead of failing its tests. When
reading the flags fails, the lane warns and builds for `baseline`; a missing CPU model
line only warns.
SHA extensions keep artifact digests on the hardware path. Every cache key is
`kosmos-native-v6-<os>-<arch>-0.17.1-<host target>-<cpu>/<lane>/<lock>-<run id>-<attempt>-<phase>`,
where 6 is the workflow's `KOSMOS_CACHE_VERSION`, and every restore prefix names the
same host target and CPU, so host artifacts hit on
every runner model that chooses the same CPU. The consumer lane builds the extracted
package for the same target and CPU, from a fixed scratch path, with the lane's own
global cache, and `test/native_consumer/build.zig` passes `-Dhost-target` and
`-Dhost-cpu` on to its Kosmos dependency, so the dependency's packaged-artifact emitter
builds for them as well. The source lanes' nested `zig build emit-examples` runs Horos's
own `build.zig`, which builds its emitter and authoring cases for its qualification
host; on every x86_64 Linux runner that is `x86_64-linux.5.10...7.2-gnu.2.31` with the
`baseline` CPU, whatever the runner model. Horos takes no host option and rejects an
unknown one, so those tools keep `baseline`. Zig compiles its build runner (`maker`, in
the global cache) and each cache's configure script for the runner itself, so only those
vary by runner model.
Builds without either option stay native; `-Dhost-cpu` without `-Dhost-target` is
rejected, and a host target must name its architecture, OS and ABI. `-Dhost-target`
changes only host tools, emitters and native tests: `-Dtarget` still defaults to
`native`, so public modules and `zig-out` keep the native target unless `-Dtarget` is
given, and then build separately from the host modules unless both name the same target
and CPU.
Every lane compiles before it runs a check: the native lanes with their `build-*`
steps, every other lane by running its `zig build` arguments once with
`-Dcompile-only=true`, under which each requested step depends only on the compilations
it reaches (Zig still runs the steps that generate their sources), and then again
without it. A cold lane can take most of the run's 600 s budget (sessions took 548 s on
an EPYC 7763 in run 45946785256), and a run that exceeds the budget recovers by a full
rerun, so every lane saves its compilation before its checks: `tools/zig-cache.sh stage`
moves what the compilation did not use out of
`.zig-cache`, the lane saves the rest under the `compiled` phase, and `unstage` moves
everything back before the first check, so the checks still find every restored unit.
At the end of a lane in which every step succeeded, `tools/zig-cache.sh admit` prunes
all of `.zig-cache` (the build caches, the nested builds' caches `source-examples/` and
`native-consumer/`, the independent core rebuild's caches and Zig's global cache) to what
the whole job, compilation and checks, read or wrote, and the lane saves it under the
`checked` phase. A failed or cancelled
lane saves nothing at its end; its compile save, or the previous entry, stays.
Every saved tree carries `kosmos-cache-record`, which lists every other entry of the
tree, directories included, by type and path, with the size of each file, so a restored
tree that lacks even an empty output directory differs from it. Directly before `track`,
a lane that saves builds the pairing tool in its own step: `tools/zig-cache.sh tool`
compiles `tools/zig-cache-pairs.zig` for the lane's host target into
`$RUNNER_TEMP/zig-cache-pairs`, with its own local and global caches there, so the
build neither reads nor writes `.zig-cache`, depends on nothing an earlier job saved and
is equally cold in every job, and the binary exists only once this job's build finished.
Both saves archive the tree at `.zig-cache.saved`: the stage and the admission rename
`.zig-cache` to `.zig-cache.saved` as the last thing before their save, and `unstage`
renames it back. The restore therefore extracts into `.zig-cache.saved`, never into
`.zig-cache`. An extraction can outlive its restore: when the restore's one-minute
timeout stops the action, the runner stops the action's own process, which need not stop
the `tar` it started, and terminates whatever still carries the job's
`RUNNER_TRACKING_ID` only when the job ends. Such a process writes below
`.zig-cache.saved` by path, or into a file it already holds open, and a child that a
compilation, a save or a check leaves running can do the same below `.zig-cache` or
`.zig-cache.saved`. Every cache step that reads, prunes, records, seals or renames the
tree, `track`, the stage, `unstage` and the admission, therefore first stops what earlier
steps left running, with the access mark held aside: it lists every process that carries
the job's `RUNNER_TRACKING_ID` and is neither the step nor one of its ancestors, sends
each SIGKILL, and repeats the listing until it finds none left, so it waits until each
process the signal reached has exited and also stops a process one of them started after
a listing. A process whose SIGKILL fails while it is still listed (`EPERM`, for one the
job cannot signal) counts as left and is named with `(SIGKILL failed)`; a process that
exited before its signal is neither waited for nor named. The step warns with their
names when there were any, and only then touches the tree, so nothing an earlier step
started can write into it afterwards: `track` then renames `.zig-cache.saved` to
`.zig-cache.restored` and verifies it, so a file such a process held open reaches
`.zig-cache` only as part of a tree that matches its record, and the stage and the
admission list, prune, record and seal a tree nothing else writes.
When `RUNNER_TRACKING_ID` is unset or the job's processes cannot be listed, the step
warns and skips. The listing stops at a deadline 10 s (half the step's 20 s limit,
leaving the step's own work, at most 5.1 s measured, the other half; in bash's whole
`SECONDS`, so 9 to 10 s) after the first listing: when a pass at or after it still
finds a process left, the step warns
`what earlier steps left running did not exit within 10 s of SIGKILL:` with every
process it signalled or failed to signal, and skips. A step that skips for any of these
reasons has not touched the tree and gives no mark back, so no later step saves: `track`
deletes the restored tree, `.zig-cache.saved`, so the lane compiles from nothing; the
stage and the admission save nothing; `unstage` leaves the compile save's tree in
`.zig-cache.saved` and the units it set aside where they are, so the checks compile from
nothing. What that pass found is left running: a process whose SIGKILL has not taken
effect yet (one blocked in uninterruptible I/O) or failed. It runs until it exits or the job ends, and
can keep writing into the tree or a file it holds open, but nothing it writes is saved.
The deadline bounds only this cleanup, not qualification: the lane's compilation and
checks run as usual, and the 600 s gate stays their only time limit.
`track` renames the tree to `.zig-cache` only
when the restore succeeded and the tree matches its record, and deletes it otherwise, so
a partial extraction never becomes the working cache and the lane compiles from nothing.
A restore can succeed after a partial extraction: the pinned `actions/cache` 5.1.0 turns
a failed `tar` into a `Failed to restore` warning and a cache miss, leaves what it
extracted, and the step succeeds.
It then checks on the workspace filesystem that reading a file updates its access time,
marks every restored file unread, and records the change time of a file it touches,
waiting until a second touch reads a later change time, so every later write follows
the mark.
Since the pairing tool and the compile save read what they open, `unstage` marks every
file unread again from a new mark and remembers what the compilation used whenever the
stage got as far as the pairing tool: the stage writes the units the job used, from the
access and change times it listed, before it runs the tool, and `unstage` re-arms
whenever that list exists, so a tool that read manifests and then failed cannot make the
admission count them as used. A stage that stopped before the tool read no file, and
`track`'s mark stands. The stop at the start of `unstage` keeps the new mark exact: a
compile save stopped by its one-minute timeout can leave its `tar` running, and that
`tar` follows the directories it opened into `.zig-cache` once `unstage` renames the tree
back, so its reads after the mark would count units the job never used. The
target identity diagnostic reads the restored builtin modules in `.zig-cache.saved`
before `track`, so its reads count for nothing.
The admissions keep a unit (a manifest, output, configuration, ZIR file, builtin module,
package archive or extracted package) when the job read or wrote it; a file counts as
written when its change time follows the mark, which extraction cannot preserve. Zig
0.17.1 finalizes a manifest under `h/` for each step it caches and stores the step's
output in `o/F` or its configuration in `c/F`, where F is the digest
`std/Build/Cache.zig` computes from the manifest's file name and the file digests it
records (`finalDigest`); it reports a manifest hit as cached without checking that the
output exists. `tools/zig-cache-pairs.zig` computes F with Zig's own `Cache.hasher_init`
and manifest layout, and lists the inputs a manifest records under the local or global
cache (builtin modules, generated files). A manifest is kept together with its output
when the job read or wrote either, and removed with it otherwise; a kept manifest also
keeps the cache inputs it records, which a hit checks, transitively: when such an input
lies in another manifest's output, that manifest and the inputs it records are kept as
well. A manifest that names no existing output is removed from every save; for a Run
step without side effects and without outputs, which Zig 0.17.1 caches by manifest alone
(`lib/compiler/Maker/Step/Run.zig:560-605`), that step runs again next time. Zig's
build runner depends only on the Zig version and the runner (its CPU and kernel
release), and building one takes 50–100 seconds, so a tree also keeps the build runners
of its recent jobs, with their manifests and recorded builtin modules. Every saved tree
carries `kosmos-build-runners`, one line per saved job, newest first, naming the build
runners that job used; `track` sets the restored lines aside. A save writes the job's
line followed by the five newest restored lines, keeps every build runner they name, and
prunes every other build runner the job did not use. An entry therefore holds the build
runners of at most the six newest saved jobs it descends from: at most 6 per global
cache (12 for native-driver, whose core rebuild has its own), and so at most 64,069,014
bytes of build runners per global cache in the tree at the measured 10,678,169 bytes
each. A lane on a runner model and kernel among those six skips the build-runner
compilation and rebuilds only its configure scripts. Temporary directories are emptied.
A save is skipped with a warning when reads leave no access time, when the tree holds an
entry that is neither a regular file nor a directory (a symbolic link, FIFO or socket;
the warning names it), when the pairing tool is missing or fails (it is missing after a
build that failed, was stopped or skipped, and fails on any manifest it cannot open or
read), when the job used no compiled output, or when the tree exceeds 1,000,000,000
bytes, about twice the largest measured (native-driver, 498,240,971 bytes). A missing
pairing tool skips only this job's saves: the next job builds it again from nothing,
whatever this job saved.
Cache work never fails or changes the outcome of a qualification lane, and the time it
adds is bounded. The restore, the target identity diagnostic,
the pairing tool's build, `track`, the stage, both saves, `unstage` and the admission
each carry `continue-on-error: true` and `timeout-minutes: 1`, so a failure or timeout
shows as a failed step, with a `::warning::`, and the lane goes on. None of them can
leave a cache that changes what a check computes. Zig reports a manifest hit as cached
without checking its output, so a manifest present without its output would fail its
step, while a missing manifest only recompiles: the restore never writes `.zig-cache`,
`track` moves only a verified tree there, the stage sets every manifest aside before any
other unit, and
`unstage` returns every other unit before any manifest, so wherever either stops, no
manifest is present without its output. A cache-tool failure skips every later save
instead of continuing on partial data: `tools/zig-cache.sh` stops at the first failing
command and writes `save=true` last; `track` writes its access mark last; the stage,
`unstage` and the admission take the mark when they start and put it back (`unstage` a
new one) only when they finish or skip cleanly, not when they skip because they could
not stop what earlier steps left running, so after a failed or killed step no later step
finds a mark and none saves.
Every cache step has a time limit chosen from measured durations. In the 84 lane runs of
runs 45946785256, 45948208955, 45957239435 (both attempts) and 45976374805 (both
attempts), timed from the job logs, the restore took at most 3.9 s, `track` 4.3 s (while
it still built the pairing tool), the stage 5.1 s, the
compile save 4.8 s, `unstage` 4.9 s, the admission 1.6 s and the checked save 4.6 s; the
pairing tool's cold build, timed in the 14 lanes of run 45946785256, none of which
restored a cache, took 2.5–4.3 s. `tools/zig-cache.sh` runs the tool's build, `track`,
the stage, `unstage` and the admission each under its own `timeout`, which stops it after
20 s, about four times the longest measured, with SIGTERM and 1 s later SIGKILL. It then
warns by the step's exit status: 124, `timeout`'s own, as exceeding its 20 s limit and
being stopped; 137, a SIGKILL from `timeout` or from elsewhere (the kernel's OOM
killer), as exceeding its limit and being killed when 20 s had passed, and otherwise as
killed after the seconds it ran, before its limit; any other nonzero status as failed
with that status. In each case no later step saves. When `track` skips, fails or is
stopped before the restored tree is verified and in place, `tools/zig-cache.sh` deletes
it, at `.zig-cache.saved` or `.zig-cache.restored`, under a
second 20 s limit (the restore, which downloads and writes the same tree, took at most
3.9 s) and warns, without failing the step, if the deletion fails or is stopped.
The restore and both saves are actions, whose step timeout GitHub counts in whole
minutes (the runner's `StepsRunner` takes `timeout-minutes` as an integer), so they keep
`timeout-minutes: 1`, and the runner ends a timed-out step within 10 s more (SIGINT,
7.5 s, SIGTERM, 2.5 s, then a kill). With every cache step hanging until it is stopped,
the cache work before a lane's checks (the restore, the tool's build, `track` and its
deletion, the stage, the compile save and `unstage`) adds at most
70 + 21 + (21 + 21) + 21 + 70 + 21 = 245 s,
and the cache work after them (the admission and the checked save) at most 21 + 70 = 91 s,
beside GitHub's start-up of each step (under 0.1 s in these logs). The target identity
diagnostic, which `main` already ran on the native and source lanes, is not cache work
and keeps its own one-minute timeout (0.2 s measured).
No cache step reads the job's clock or skips for how far the job has got: each is
bounded only by its own limit, and `track`, the stage, the compile save, `unstage` and
the admission run whenever every earlier step succeeded or was tolerated. The only times
a cache step measures are its own: `stop()`'s 10 s deadline and how long a killed step
ran. The runtime budget gate's 600 s, measured from
the start of the run attempt, is the only pass/fail time limit. Each lane's job carries
`timeout-minutes: 20` only as a backstop against a runaway step: a lane still running
after 600 s already fails its attempt's gate, and the gate passes a later attempt only
when that attempt ran every lane itself, so the limit decides no attempt's outcome and
leaves passing attempts unchanged. Cache work counts against the gate like any other
step, by the limits at most 245 s before a lane's checks and 91 s after them, 336 s in
all. Measured, it took 10.2 s per lane at the median of those 84 lane runs and 16.9 s
at most, when most lanes restored the pairing tool's build; built cold in every job that
saves, the tool adds 2.5–4.3 s to each. Cache work can push a lane past its 20-minute
limit only when the lane's other steps take more than 1,200 − 245 − 91 = 864 s, so only
in a lane that fails the gate without it.
Every lane that finishes compiling therefore leaves its compiles for the full rerun,
unless a cache step fails or the tree cannot be saved (no access times, an entry neither
a file nor a directory, no pairing tool, nothing used, over the ceiling): the stage and
the compile save run directly after the last compilation, whenever it ends, and take at most 21 + 70 = 91 s, so they finish
before the job limit for any compilation that ends by 1,109 s into its job, far later
than any lane
that can pass the gate (every compilation measured so far ended by 388 s: native-driver,
cold, in run 46010143728). The entry is stored whatever the lane does next; the lane's
retention job runs after a failure or cancellation too and keeps the lane's newest entry
(its checked save if the lane got that far, its compile save otherwise); and the full
rerun's restore finds it under the lane's `<lane>/<lock>-` restore key, which returns the
newest entry. A lane that succeeds also stores its checked save, however late its checks
end.
The stage, both saves, `unstage` and the admission carry no status condition, so GitHub
runs each only after every earlier step has succeeded or been tolerated, and the
admission and its save are the lane's last steps. A failed compilation saves nothing. A
compilation after a discarded restore starts from an empty cache, so the set it saves is
complete. Fork pull requests restore compiler caches, this workflow never saves theirs,
and runs on branches other than `main` save none either; neither builds the pairing
tool. A fork pull request runs its own copy of the workflow, which its author can edit
to save caches under the pull request's ref; a returning contributor's fork can run
without approval, depending on the repository's approval setting, which is the owner's.
Such saves fall outside the bound below.
`Keep one compiler cache per lane and CPU` runs after every lane of a run on `main` or a
same-repository pull request, also after a failure or cancellation. It checks out
nothing and runs on a GitHub-hosted runner with only `actions: write` and
`pull-requests: read`. For each host target, CPU and lane on the run's ref it keeps the
entry with the highest run id, attempt and phase (`checked` after `compiled`), read from
the key rather than from the creation time, so an older run that saves last never
displaces a newer run's entry; run ids, unlike run numbers, never restart. A newer run's
or attempt's `compiled` entry therefore replaces an older `checked` one, although it
holds only what compilation used and the next run compiles the checks' units again,
because the full-rerun recovery needs the newest entry, even a compile-only one, to
seed the rerun. It deletes the
others and every entry of an older key version (`kosmos-native-v<N>-` with N below the
workflow's `KOSMOS_CACHE_VERSION`, or with no version); a newer version's entries, saved
by a later workflow on the same ref, stay. If
the ref's pull request has closed, it deletes every cache of the ref. Closing a pull
request runs `Closed pull request caches` from the base branch through
`pull_request_target`, also without checkout and with only `actions: write`; it deletes
every cache of the pull request's merge ref. A run still in progress at the close can
save after that, and its own retention job then finds the pull request closed and
deletes those saves. Neither job can turn a run red. Each warns about a failed deletion
and waits up to 30 seconds for the cache list to drop deleted entries, then warns about
any still listed; a command that fails (an API error while reading the pull request or
listing caches) stops the step with a `::warning::` naming it, before any later
deletion; and the step carries `continue-on-error: true` and a four-minute timeout, so
a hang is stopped and tolerated. A retention succeeds when it finishes without a
warning. `Closed pull request caches` reports as deleted only the entries its last
listing no longer holds.
Retention never deletes a newer version's entries, so a ref's entries are counted per
cache version. A successful retention by a run of version v leaves the ref no entry of a
version below v and at most one entry per key prefix and lane of v, and leaves each newer
version as that version's own last successful retention on the ref left it. Beside the
saves no such retention has covered (counted below), a ref therefore holds of each cache
version at most the set its last successful retention of that version kept: one entry
per key prefix and lane, so C sets of 14 entries, where C is the number of key prefixes
of one version. Those are the CPU classes its runs chose,
C ≤ 2, while the workflow fixes the OS, architecture, Zig version and host target in the
prefix; changing any of them without raising `KOSMOS_CACHE_VERSION` adds prefixes to C.
A ref holds the sets of more than one version only after a run of an older version
retains after a newer version's retention on that ref: a full rerun of a run from before
a version bump, which runs that run's own workflow, or an older run that finishes last.
Such an older-version set stays only until the next successful retention of a newer
version on that ref deletes it; on `main`, every push runs the newest version. Forks
and branches other than `main` hold none. Each run attempt whose saves no successful
retention of their version or a newer one on their ref has yet covered adds at most two
entries per lane (its compile and job saves); every attempt saves under its own keys and
has its own retention job, and an attempt whose retention is still to finish, stopped
with a warning, timed out or was cancelled, keeps them until a later retention of the
same or a newer version on the same ref succeeds. A closed pull
request's ref holds none once `Closed pull request caches` or a later retention on it
succeeds; when that cleanup stops with a warning, times out or is cancelled and no run
follows, its entries stay until GitHub removes caches unused for seven days.
These counts hold for the entries of this workflow and its later versions. A full rerun
of a run from before it, possible for 30 days after that run, saves under that run's
workflow, which on `main` saves `kosmos-native-v2-` entries of up to 4 GiB per lane and
runs no retention; such entries fall outside the bound until a successful retention on
their ref deletes them as an older version.
The code enforces those counts, at most six jobs' build runners per entry, and the
1,000,000,000-byte ceiling on each entry's tree (each archive GitHub counted for this
pull request was smaller than its tree). Those alone allow 1,000,000,000 bytes per
entry, which keeps `main` safe only up to nine entries, so the bound below rests on
measured sizes. S bounds a set of 14 entries including the build runners each keeps
for its history. Measured: run 45946785256 saved the largest set, 1,008,556,734 bytes
compressed for 14 entries with one build runner per global cache, and a build runner is
2,591,504 bytes compressed. The history keeps at most five more build runners in each
of a set's 15 global caches, so S = 1,008,556,734 + 75 × 2,591,504 = 1,202,919,534
bytes. With P the same-repository pull requests whose ref holds caches (every open one,
and a closed one whose cleanup has not succeeded, for up to seven days), O the
older-version sets (summed over refs, the cache versions whose retained set a ref holds
besides its newest such version) and F the run attempts whose saves no successful
retention of their version or a newer one on their ref has covered, the compiler caches
total at most ((1 + P + O) × C + 2F) × S, beside `main`'s Zig tarball saved by the setup
action (57,413,921 bytes). GitHub evicts caches only above 10 GB, so pull request caches
can cause `main`'s to be evicted only if that total plus the tarball exceeds 10 GB; at
the measured sizes the total stays below 10,000,000,000 bytes while
(1 + P + O) × C + 2F ≤ 8: with every runner choosing `x86_64_v3+sha` (C = 1, as in every
run so far), while P + O + 2F ≤ 7; with both classes (C = 2), while P + O + F ≤ 3. O is 0
while every run of this workflow carries version 6, as now. After a version bump its
worst case counts, on each ref, every older version of this workflow whose runs on that
ref can still be re-run, each only until that ref's next successful retention of a newer
version.
A run that fails the gate or is cancelled keeps, for each lane, its compile save if the
lane finished compiling and its job save if the lane succeeded; the full rerun restores
them.
The native owners, ordinary driver and checked recovery driver each compile on
a separate runner.
The ordinary driver uses the legacy compiler and compares the shipped artifact
byte for byte with the independently regenerated core. The checked recovery
driver uses the optional compiler and the authenticated packaged core to exercise
both branch paths and restore interrupted phases. The local `check-semantic-driver`
and `check-native` targets include both suites.
The ordinary specialization lane compares the legacy compiler's transitions to the
frozen native baseline. The recovery specialization lane checks compiler identity and
source export with the optional compiler. Both belong to `check-semantic-specialization`
and `check-native`. The ordinary specialization suite runs their shared runtime tests.
The Zig installation uses a stable tool-cache path because dependency extraction
includes `PATH` in its input identity; Node is set up before compilation for the same
reason. Neither cache restoration nor successful compilation substitutes for completed
tests.
The other lanes use `-Dpackaged-runtime=true` to authenticate the exact shipped
artifact whose source correspondence the native semantic lane checks. All lanes
retain full runtime artifact and guest-state admission.
Matching compiler artifacts are restored and missing inputs are rebuilt; every
selected test still executes. Every runtime lane's job has a 20-minute limit, only a
backstop against a runaway step. The runtime budget gate first lists its own run
attempt's jobs. GitHub lists a job that a rerun of only the failed jobs, or of one job,
did not run again under the new attempt's number but with its original start time,
which precedes the attempt's start. The gate therefore fails, telling the maintainer to
re-run all jobs, when any `Qualify / ` job started before its attempt or none is listed;
otherwise it checks elapsed time from the attempt's start against 600 seconds without
waiting for TigerStyle. The terminal gate requires both the bounded runtime
qualification and the exempt TigerStyle job to succeed. The 600-second gate is the
only pass/fail time gate: a cache step's own limit and `stop()`'s deadline end only
cache work, never qualification: after either fires, no later step in that job saves a
compiler cache, and the compiler cache retention job runs outside both gates. A truly
cold run on a slow runner can exceed 600 seconds; recover with a full rerun of the whole
workflow, since a rerun of only its failed jobs fails the gate. Before this check, such a
rerun re-ran only the failed gate whenever every lane had succeeded, and the gate measured
seconds from the new attempt's start; that let a run pass without any attempt qualifying
within 600 s, both when a lane ran past 600 s and, already on `main`, when queueing
pushed a run whose lanes each fit their limit past 600 s. The gate now refuses both.
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
The current artifact digest and selected Horos package identity are recorded in
[`src/semantic_packaged.zig`](../src/semantic_packaged.zig), alongside the checked
source digest. The exact qualified revision and command outcomes are recorded in
[the consolidation PR](https://github.com/tkersey/kosmos/pull/76).
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

CI runs the same commands on the hosted Ubuntu image, whose preinstalled
libraries satisfy both browsers, so the lane needs no package mirror.
Python/Wasmtime is not part of the current checks.

## Request-checked diagnostic replay

`check-semantics` imports focused strict replay cases alongside the unchanged
hypothetical-analysis tests. Fixed request/value bytes distinguish matching,
wrong payload/effect, out-of-range effect, reordered and repeated occurrences,
prefix exhaustion, missing/unused exchanges and complete terminal mismatches.
Canonical checkpoints and step counts are compared with the pinned independent
native evaluator. Shared admission and codecs are not independent implementations.

Cases cover malformed matched replies versus ignored malformed unmatched replies,
binding/start rejection, noncanonical input, constructor buffer ownership,
separate capture choices, zero-quantum parked replies, initial/reached yield,
ordered cleanup failures, cancelled/unwinding starts and retained multishot control.
Small pumps restore analysis checkpoints throughout execution after overwriting
caller input. Subject and analysis checkpoints cannot be swapped. Focused
allocation-failure sweeps cover construction and decoded result ownership.
Equal pending observations with distinct retained state exercise the separate
canonical-state comparison; terminal collection can erase that earlier difference.

`check-semantic-driver` runs the same implementation as the
[`diagnostic-replay` example](diagnostic-replay.md). It exercises real publication
failure/retry without redispatch, failed-attempt trace scratch, scoped retention,
default summary output, physical limits, inert action-shaped output and a separate
live owner. Isolated reference/instrumented and unapproved unequal runtime
experiments compare actual aligned observations and canonical states. An existing
uncertain realization remains fenced after successful replay until its original
owner resolution. Existing receipt, issuer/generation, custody and artifact checks
remain in their original roots.

`check-kernel` executes one exact compiled replay image and matching/mismatching
inputs through native and WASM paths, comparing complete canonical results and
captured guest state. Its minimal one-request guest returns the supplied response
directly; the richer two-request retained-blob scenario remains in the native
integration example. This keeps portable qualification focused on real execution
and transfer through the additional evaluator layer. Native execution supplies
the uninterrupted result. WASM execution starts with the same image and input,
transfers an interrupted analysis checkpoint, and finishes in a fresh instance
after caller-input mutation. Native restoration of that checkpoint must also
produce the same complete result. This combines portability and restoration
checks in one WASM execution per case. `check-browser` executes and
restores the compiled analysis through fresh Chromium and Firefox Workers using
the unchanged byte API. No authoring compiler or live adapter is added to them.
Both build steps retain `has_side_effects` so each invocation executes the checks.
They require exit zero and their completion marker through buffered stdout checks,
allowing independent processes to run without Zig's inherited-terminal lock.
CI runs the browser check in a separate required matrix lane, so browser engines
and Node kernel checks do not compete on one runner. Both lanes build from the
same commit and authenticated inputs; compilation may be duplicated. The existing
aggregate 600-second gate requires both lanes, including their cache-save steps.

The replay constructor and example are outside the explicit retained semantic
source closure. They do not change `semantic-core.kar`; the existing driver root
still compares that artifact with independent fresh source generation. BPI3,
PST3, invocation envelopes and ABI 3 remain unchanged.

These are finite witnesses. They establish neither transcript authenticity,
universal runtime equivalence nor external exactly-once execution. Diagnostic
timings use the separate optional `diagnostics` benchmark selector and impose no
CI timing gate. Runtime qualification retains its existing 600-second budget.

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
