# Kosmos kernel ABI 3 and byte embedding

`src/kernel/main.zig` compiles one import-free wasm32 module from the stable
evaluator. It defines unshared memory with a declared maximum (256 MiB by default)
and no start function. Programs are BPI3 data; adding an application does not
recompile the kernel. Production construction imports Horos's pure data module
only. Fixture compilation is an explicit, separate test build.

## Exports and buffers

The only non-function export is memory. All pointers/statuses below use wasm i32
(pointers interpreted unsigned); identities, handles, lengths and quanta use i64
(interpreted unsigned). Every function returning status uses 0 success, 1 physical
capacity, 2 rejection. Capacity status publishes PKO3 `needs_capacity`; rejection
publishes only a bounded diagnostic name and zero output length.

| Export | Parameters | Result |
| --- | --- | --- |
| world_abi_version | none | i32 = 3 |
| world_initialize | instance:i64 | status |
| world_set_limits | instance, input_limit, working_limit, output_limit:i64 | status |
| world_prepare_input | instance, length:i64 | status |
| world_input_ptr | none | i32 |
| world_input_capacity | none | i64 |
| world_output_ptr | none | i32 |
| world_output_len | none | i64 |
| world_error_ptr | none | i32 |
| world_error_len | none | i64 |
| world_prepared_handle | none | i64 |
| world_session_handle | none | i64 |
| world_working_live | none | i64 |
| world_working_peak | none | i64 |
| world_invoke | instance, length:i64 | status |
| world_prepare | instance, length:i64 | status |
| world_release_prepared | instance, handle:i64 | status |
| world_start | instance, prepared_handle, length:i64 | status |
| world_restore | instance, prepared_handle, length:i64 | status |
| world_drive | instance:i64, session_handle:i64, control:i32, quantum_present:i32, quantum:i64, checkpoint:i32, length:i64 | status |
| world_checkpoint | instance:i64, session_handle:i64, transfer:i32 | status |
| world_close | instance, session_handle:i64 | status |

Initialize once with a nonzero host-selected instance namespace. Every subsequent
command checks it. Handles increase monotonically within that instance, never
reuse a released generation, and do not enter Program, State or application values.
There is one externally owned preparation slot and one resident slot. A Session
retains its preparation after `world_release_prepared`. Creating a second object
in an occupied slot rejects. These names are local handles, not global uniqueness
or distributed ownership claims.

Call prepare_input, then reacquire memory.buffer and input_ptr before copying bytes.
The consuming call must use exactly the prepared length. There are no arbitrary
caller-supplied memory pointers. Memory growth can invalidate old host views;
reacquire output pointer/length afterward and detach output before the next command.
Set_limits invalidates staged input. Each command may invalidate prior output.

Invoke consumes PKI3 and publishes PKO3. Prepare consumes BPI3 and publishes a
prepared handle. Start consumes typed initial-argument bytes; restore consumes
PST3. Both publish a session handle. Drive payloads are: control 0 none (empty),
1 ERS3 reply, 2 resume_yield (empty), 3 UTF-8 cancellation text, 4 cancellation
bytes. Quantum-present/checkpoint are exactly 0 or 1; absent quantum requires a
zero quantum argument. Resident drive publishes PKO3 with optional checkpoints.

Quanta count evaluator work units. On 64-bit native storage, a final reusable,
capture-free callable construction and its immediate handler installation may
execute together when
both units fit the remaining quantum and the callable has no other use or
retained edge alias. Explicit single-step keeps the intermediate boundary. Both
units count toward collection cadence; argument/state evaluation, external
operations and cleanup keep their source order. Published boundaries remain
checkpointable and portable. WASM retains ordinary execution with the same work
accounting and logical boundaries.
Checkpoint publishes PST3, with transfer 1 relinquishing the resident only after
successful output allocation. Close requires terminal state. Stale/wrong handles,
wrong instance, malformed controls and reentry reject without advancing State.

## Capacity and publication

Initial input/working/output budgets are 64 KiB / 128 MiB / 64 KiB. The initial
working backing is 1 MiB. A coalescing allocator reuses freed storage and grows
within the module's declared maximum. Live-byte budgets are separate from reserved
linear memory and allocator metadata; fixed emergency capacity/diagnostic buffers
also remain outside those dynamic budgets. Working includes immutable preparation,
execution storage and temporary analysis/transaction work; input and final output
buffers have distinct budgets. The working counters report requested live/peak
bytes, not RSS or a claim about allocator slack.

Limits may be raised explicitly. Working may not shrink below its current live
allocation. Capacity reports distinguish the failed budget from memory.grow
failure, with exact final-output demand or observed lower bounds as appropriate.
Internal decoder limits remain separate physical limits and may report unknown
required working capacity. They are not authored value bounds.

Fresh and resident output allocation use separate working/output allocators.
Resident encoding allocates the final output inside its transaction; capacity
failure retains the same checkpoint, handle and pending response binding. A host
can raise capacity and resend the already obtained ERS3 without repeating the
external operation. Checkpoint transfer likewise retains custody on failure.

## Environment-neutral JavaScript

`src/embedding/kernel.mjs`, `codec.mjs` and their helpers use supplied bytes,
WebAssembly, TextEncoder/TextDecoder and Web Crypto, with no Node or filesystem
imports. `Kernel.create` requires an exact expected SHA-256, owns the bytes before
the asynchronous hash, statically verifies the export signatures/memory profile,
then instantiates. It has no authentication bypass option.
The expected digest must come from the embedding's trusted artifact metadata;
computing it from an untrusted incoming kernel would not establish authenticity.

The wrapper's prepared/session tokens belong to the actual Kernel object through
a private WeakMap; copied, released and cross-instance tokens reject. Returned
bytes are detached copies. Shared mutable input buffers and forged Uint8Array
brands reject. Invocation codecs retain the schema-directed value rules, including
zero-size cardinality, bounds and UTF-8. Environmental tool semantics and checkpoint
persistence remain the caller's responsibility.

## Build and verification

`zig build build-kernel` builds the generic ABI 3 kernel without constructing
Horos's authoring compiler. `zig build build-runtime check-package` builds the
ordinary standalone JS package and exercises its extracted public API and CLI.
These commands do not publish a release or create a qualified-v1 bundle.

See [verification boundaries](verification.md) for the native, independent source
and optional JavaScript checks and browser setup. Current qualification runs the
same Worker/native transfer cases in Chromium and Firefox. Exact subjects and
executed results belong to the current PR.

The installation fixture checks initial working-capacity rejection and successful
unchanged-input retry with an explicitly larger budget. It does not claim that
all applications fit the initial budget. The CLI writes PKO3 to stdout and keeps
filesystem loading in its Node-only adapter.
