# TigerStyle for Kosmos

This contract applies to every tracked Zig file, including implementation, tests,
examples and build tools. It adapts the
[skills-zig TigerStyle contract](https://github.com/tkersey/skills-zig/blob/ac19a3fabd0b32fae3f6bf1becf5368c724e96f3/docs/engineering/TIGER_STYLE.md)
to Kosmos's executable semantics and native/WASM runtime. Safety, performance and
developer experience are the priorities, in that order.

## Design and ownership

Start from the required observations, valid inputs and rejected states. Identify
the owner of each state transition, the capabilities it may use, and the exact
point at which a successor becomes authoritative. Prefer constructions that
preserve these relationships through their permitted operations.

Keep the following runtime laws explicit when changing their owners:

- Admit complete programs, typed replies and restored states before using them.
- Publish a successor only after admission and output encoding succeed. On a
  physical failure, preserve the preceding authoritative state for retry.
- Bind replies to the current request and receipts to their issuer and committed
  generation. Copied checkpoints do not establish exclusive execution custody.
- Preserve authored results, effect order, cleanup and continuation multiplicity
  across native/WASM execution, suspension and restoration.
- Treat cancellation and cleanup as executable operations. Local rollback does
  not reverse an external effect or authorize repeating it.

These are the existing [runtime](../README.md#state-and-effects) and
[verification](verification.md) contracts. Style adoption does not change them.

## Work, allocation and control flow

Every implementation path needs an explicit resource and progress argument:
admitted input size, caller-selected quantum or capacity, bounded collection, or
supported unbounded execution. Quanta bound internal transitions while preserving
authored results and effect order. An unbounded invocation may diverge when its
program diverges; do not impose a new global step or memory ceiling to satisfy a
style check.

Replace native implementation recursion with explicit worklists whose ownership
and growth policy are checked. Authored recursive programs and retained control
represented as Horos data remain supported. This rule concerns the native call
stack, not the language's recursive computations.

Keep ordinary loops structurally bounded or make their termination measure
visible in the construction. Intentional event loops need the auditor's same-line
`tiger: event-loop` directive and a concrete progress/resource justification in the
change description. A marker alone does not establish bounded work.

Allocate through the caller's explicit allocator and preserve its lifetime.
Dynamic allocation is permitted; retained state, scratch, snapshots and output
buffers have distinct owners. Return allocation and capacity failures through the
existing outcomes. Avoid borrowing collection element pointers across growth or
release. Check size arithmetic and conversions before allocating or indexing.

Use fixed-width integers for wire fields, persistent identities and externally
visible sizes. `usize` remains appropriate for in-memory indexing and allocator
interfaces. Put units or qualifiers last in names, such as `output_bytes_max`.

## Errors and invariants

Distinguish programmer errors from expected operating failures. Assert internal
invariants and relationships between compile-time constants. Return malformed
input, resource exhaustion and environmental failures through their declared
error paths; do not discard them with `catch {}` or `catch unreachable`.

Keep one owner for mutable transitions, shorten aliases and group acquisition
with release. Pass I/O, allocator and host capabilities explicitly. Assertions
support a construction; passing assertions do not establish complete ownership,
termination or recovery correctness.

## Source shape

Keep functions and test blocks within 70 physical lines, with descriptive
names and narrow responsibilities. Keep Zig source lines within 100 columns;
passive multiline-string data is exempt from the line-length check. Use spaces,
remove trailing whitespace and resolve `TODO`, `FIXME` and `HACK` markers before
merging code.

Express explanations through names, types, ownership and operations. Do not add
explanatory comments to source, tests or examples. Mandatory legal notices and
required machine directives remain permitted. Put engineering rationale in the
PR description when it helps assess the actual change.

The auditor counts each function or test block's own physical lines. Nested
functions and methods have independent limits; their lines do not inflate the
enclosing type factory. Shared lines still count for each owner containing code
on that line. Blank lines belong to their enclosing function. Type-returning
factories and mandatory inline expansion do not create native recursive frames;
their nested runtime functions still receive recursion checks.

## Performance and verification

When a data path changes, identify its relevant allocation, copying, encoding and
execution costs. Measure the affected path while preserving output bytes,
failure atomicity and the same behavioral obligations. Cache only values with
explicit identity, invalidation and ownership.

Use the existing [qualification roots](verification.md#run-the-checks) for the
changed boundary. Include valid and invalid admission, boundary values, stale or
mismatched identity, allocation failure and retry where they discriminate its
failure modes. Reuse small generated cases and existing fixtures. Preserve
independent evaluator and native/WASM observations; do not add repeated large
fixtures to manufacture confidence.

Every required check must complete successfully on the delivered candidate.
Stopped, skipped, timed-out and inconclusive runs remain outstanding. Record the
actual commands and outcomes in the PR. Runtime qualification retains its
600-second workflow budget. TigerStyle verification is exempt from that budget
and remains required, with an independent 10-minute job timeout.

## Run the full-source gate

From a clean source checkout with Git, Bash and Zig 0.17.0 available, commit the
candidate and run:

```sh
bash tools/tiger-style.sh HEAD
```

The optional argument defaults to `HEAD`. The checked-out committed head must
match the requested head. The launcher selects every tracked `.zig` file, runs
the pinned native auditor's self-tests and fully audits every selected file.
Unchanged files and pure renames receive the same checks as new code. There is no baseline, allowlist or historical-debt
exemption.

The native auditor remains pinned to an immutable `skills-zig` commit. Acquisition
and tool errors fail the gate. Binary-classified Zig files, nonregular source
such as symlinks, and a candidate with no tracked Zig source fail rather than
silently omit source. The auditor is a development dependency, outside the
runtime package and `build.zig.zon` dependency graph.

Full-file checks parse Zig syntax and recognize direct recursion and overlong
functions/test blocks, including nested declarations. Line-level rules remain
heuristic: multiline error/loop spellings, indirect recursion, ownership and
progress still require review. Passing the automated gate does not establish
those semantic obligations.

Run `bash tools/test-tiger-style.sh` after changing the launcher or auditor pin.
Its temporary Git histories check unchanged violations, unrelated changes, pure
renames, valid source, added violations, long existing functions, malformed
source, invalid revisions, dirty indexes/worktrees, binary source/classification,
nonregular files and empty source selection. CI runs these probes without
retaining generated fixtures.

Runtime qualification runs concurrently with TigerStyle. `Runtime qualification
budget` checks the runtime lanes against 600 seconds from workflow start without
waiting for TigerStyle. The existing `Complete qualification` check then requires
both the runtime budget gate and TigerStyle to succeed. The dedicated TigerStyle
job checks the exact PR head and remains active for main pushes and manual runs.
