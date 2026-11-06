# Request-checked replay

`RuntimeAnalysis.replay` constructs an ordinary effect-free Horos program that
interprets one exact admitted guest start against supplied request/response data.
It compares each actual effect and complete canonical request payload before
admitting the corresponding response against the actual result schema. It has no
external dispatch adapter. Existing `hypotheticalReply` and `interpretation`
remain positional hypothetical analyses, including their existing yield policy.

Run the complete offline example from a source checkout with exact Zig 0.17.1:

```sh
zig build diagnostic-replay -Doptimize=safe
```

The example retains a hidden blob, requests keys 11 and 22, and uses deterministic
responses 5 and 7. Its independent expected result is 47: the 35-byte blob length
plus both responses. It captures a real committed request, performs metadata-only
retention queries, replays authorized full data, and compares actual isolated
reference/instrumented and deliberately unequal unapproved realizations.
Two forced local publication failures reuse an acquired result without another
provider acquisition or a false committed exchange. A separate live owner's
checkpoint, request binding and receipt remain unchanged by the analyses.

## Construction and ownership

```zig
const analysis = kosmos.RuntimeAnalysis;
const replay = try analysis.replay(&builder, admitted_guest, .{
    .checkpoint = authorized_checkpoint_bytes,
}, .{});
const input = try analysis.encodeReplayInput(allocator, .{
    .transcript = .{
        .binding = replay.binding,
        .exchanges = authorized_exchanges,
        .ending = .{ .terminal = expected_terminal_observation },
    },
    .guest_quantum = 100,
});
defer allocator.free(input);
```

Lower and admit `replay.module` through the normal Horos path, then execute its
exact image/input through existing Kosmos byte APIs. The complete executable
implementation is in `src/diagnostic_replay_example.zig`, with the CLI in
`examples/diagnostic_replay.zig`. The example runner inspects lowered/admitted
programs for external effects and rejects them; it has no dispatch callback.

The constructor accepts `ReplayStart.arguments` containing canonical entry
arguments or `ReplayStart.checkpoint` containing a complete canonical PST3 for
the selected guest. It rejects malformed, trailing, noncanonical or foreign
state. Partial views and outer capsules are not complete guest checkpoints.
Embedded data is copied into builder-owned storage. The returned module has the
builder's lifetime; `ReplayProgram.binding` is a value.

`ReplayBinding.guest` is the admitted guest identity. `origin` is the tagged
SHA-256 digest of the exact admitted argument or checkpoint bytes. The transcript
binding and terminal expectation tag are checked before private initialization
or hydration. Starting from a checkpoint establishes only that segment, without
reconstructing its prior history or cancellation decision.

`ReplayCapture` has independent `observation` and `snapshot` booleans, both false
by default. The enclosing owner chooses them at construction, before tool
execution. A transcript cannot enable more disclosure. Summary mode does not
project a complete guest snapshot simply to discard it. Exact request and
terminal comparisons still inspect the bytes required by their contracts.

## Ordinary input and output records

All public records are exported through `RuntimeAnalysis`. They use existing
Horos schemas and canonical value encoding, with no new envelope or journal.

| Record | Fields |
| --- | --- |
| `ReplayExchange` | `expected_request: { effect: Id, payload: bytes }`, `response: bytes` |
| `ReplayEnding` | `prefix` or `terminal: Observation` |
| `ReplayTranscript` | `binding`, `exchanges: []ReplayExchange`, `ending` |
| `ReplayInput` | `transcript`, `guest_quantum: u64` |
| `ReplayOutput` | `binding`, `matched_exchanges: u64`, `guest_steps: u64`, `boundary: Status`, `stopping: ReplayStop`, `observation: ?Observation`, `snapshot: ?State` |

Use `encodeReplayInput` for owned input bytes and `decodeReplayOutput` for an
owning decoded result; release each with its allocator or `deinit`, respectively.
The decoded result's slices remain valid only until that result is released.
`Observation` and `State` are the existing semantic representations, including
ordered cleanup failures and distinct cancellation reason variants.

Responses are ordinary value bytes, not live ERS3 envelopes. A response is parsed
only after its request matches. An out-of-range expected effect is a safe
mismatch without a lookup through that effect. Repeated identical requests are
consumed by occurrence; replay does not deduplicate, search ahead or cache replies.
Integer values and payloads are compared canonically without JSON or float
conversion. A redacted payload cannot establish an exact match.

`matched_exchanges` counts completed private response transitions and excludes
the mismatching exchange. `guest_steps` counts only transitions performed in this
segment, excluding reply admission/application, comparisons, projections and
base evaluator work. Output contains one stopping witness, without transcript
echo or a second request history.

| `ReplayStop` | Meaning |
| --- | --- |
| `terminal_matched` | All exchanges consumed and complete terminal observation matched. |
| `terminal_observed` | Terminal state reached after the supplied prefix; no terminal expectation. |
| `prefix_exhausted` | Another actual request needs an exchange after a prefix ending. |
| `missing_exchange` | Another request needs an exchange despite a terminal expectation. |
| `yielded` | Guest is yielded; no implicit resumption. |
| `guest_quantum` | Another active/unwinding transition needs more guest allowance. |
| `unused_exchanges: u64` | Terminal guest has remaining exchanges; value is first unused ordinal. |
| `effect_mismatch` | `index`, `expected` and `actual` effect IDs identify the discrepancy. |
| `payload_mismatch` | `index`, `expected_length`, `actual_length`, `first_difference` identify the discrepancy. |
| `terminal_mismatch` | All exchanges consumed but complete terminal observation differs. |

For unequal payloads, `first_difference` is the first unequal byte offset or the
shorter length when one is a strict prefix. No payload bytes appear in this
default witness. Lengths, positions and digests can still be sensitive metadata.

Terminal inspection takes precedence over exhausted guest allowance. A starting
yield stops immediately. A parked matching request can consume a supplied
response at zero guest quantum; another active transition then stops. Yield
resumption, newly injected cancellation, realization changes and custody transfer
are absent from the transcript grammar. Natural failure and cleanup requests use
the existing lifecycle; admitted unwinding/cancelled starts retain their meaning.

These stops are completed diagnostic results. Wrong bindings, malformed records,
nonterminal terminal expectations and malformed matched responses fail the
analysis. Allocation, decoding and output failures are physical failures, never
fabricated guest failures or empty successful results. A completed replay can
separately report an actual guest failure or cancellation observation.

## Bounds and restoration

The example bounds construction and all owned allocations with a 4 GiB requested
allocation budget. Each analysis uses at most 1 MiB input, 64 MiB working
allocations, 1 MiB returned output, and 4096 pumps of 4096 base transitions.
Its fixture replay uses 100 guest transitions. Candidate source lowering was
observed requesting a 1.59 GB arena block with 0.70 GB already live; the separate
construction bound accommodates that compiler work. These finite limits fit
source generation and the small fixture without treating
guest quantum as a memory or wall-clock bound. The runner exercises zero input,
working, output and pump limits and requires explicit failures. Allocation counts
are requested bytes, not RSS. Host scheduling remains responsible for elapsed
time and isolation; a base transition can process variable-sized data.

An interrupted replay is restored as the same ordinary analysis program using
its existing PST3 checkpoint. This retains the input, private guest, ordinal,
remaining allowance and evaluation progress; it does not reread mutable caller
buffers. Analysis and subject-guest checkpoints have different program identities
and cannot be swapped. A returned subject snapshot can start a new separately
bound segment, but cannot extend a full-run agreement claim by assertion.

The program, constants, builder storage, compiled image and analysis checkpoints
can contain the entire authorized starting data. They inherit its confidentiality
even when the returned summary is small. Output from a tool that received secret
data remains sensitive unless an independently approved projection narrows it.
Typed output is not automatic declassification.

## Reading the example report

The host computes identities from the exact admitted/executed bytes. Execution
and disclosure labels within view bindings are owner assertions. Metadata-only
retention receives a distinct scoped view, with no values, blobs or snapshot.
Graph completeness and value coverage are reported separately: a target absent
from a partial graph is `unknown_partial`, while complete graph coverage can
establish `absent_complete`. A disclosed root gives a reachable witness.

Comparison uses independent `RuntimeExperiment` owners, actual guest revisions,
the same origin checkpoint and canonical semantic control identities. It stops
when alignment is lost, and compares canonical states separately from observation
bytes. Reports retain both trace lengths, compared counts, completeness flags
and stopping dispositions. Equal prefixes, unequal lengths and zero comparisons
cannot establish complete execution agreement. The negative candidate changes
the observed completion while preserving state, is rejected by ordinary relation
validation, and runs only in isolation.

Request/response agreement, terminal observation agreement and canonical state
agreement are distinct claims. None authenticates production history, approves
a runtime candidate, grants disclosure, resumes a live guest, or releases a
fenced owner. No live dispatch fallback, distributed custody, external rollback
or global exactly-once execution is provided. The publication witness establishes
only local retry without redispatch of its deterministic acquired response.

The CLI report is explanatory output, not a stabilized transport format. The
public replay API is an additive minor-release change under normal package
compatibility policy; implementation does not publish a release.

See [verification](verification.md) for qualification and
[semantic economy](semantic-economy.md) for measurement boundaries.
