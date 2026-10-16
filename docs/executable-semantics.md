# Executable guest semantics

The public guest facade runs `semantic/service.zig` as ordinary Horos code on
`base/session.zig`. The build emits `semantic-core.kar`; adding a guest image
does not rebuild the generic evaluator. The frozen direct guest evaluator is in
`test/oracle/` and is a qualification dependency only.

## Execution boundaries

| Component | Responsibility |
| --- | --- |
| `semantic/` source builders | Guest instructions, control, handlers, resumptions, graph cloning, collection, cleanup, observation, hydration and reconstruction |
| `base/profile.zig` | Exhaustive admitted-schema, opcode, terminator and bridge restrictions |
| `base/session.zig` | First-order calls, ordinary data operations, physical storage and the selected linear service bridge |
| Horos data admission/codecs | BPI3/PST3/value validity, canonical bytes, schema and ownership facts |
| `semantic/driver.zig` | Service commands, base pumping, guest response binding and separate work counters |
| `semantic/session.zig` and `interpreter_v2/resident.zig` | Public guest API, leases, rollback, publication, local receipts and fenced switching |
| Enclosing host | Runtime approval, external grants, delivery disposition, durable publication, disclosure and distributed custody |

Admission is not runtime approval. `RuntimeArtifact` checks the content address,
canonical envelope, base inventory and recovery map shapes.
`RuntimeCompiler.validate` separately checks the exact source, specialization
derivation, lowering evidence and recovery helper images. The execution owner
must approve that artifact and the work in which it will execute. Artifact bytes,
hashes and capsule provenance fields confer no external authority.

## Representation and correspondence

Guest nodes and blobs live in persistent binary forests; frame bindings use
sparse Patricia maps. Source updates rebuild the affected paths. The base keeps
ordinary aggregate children as references, so these source paths remain shared
instead of eagerly serializing the entire tree. Exported bytes are materialized
only when demanded. Stable guest IDs and canonical PST3 projection remain the
public observation.

Specialized scalar frames split bindings into disjoint ordinary and raw maps.
The raw entry is `(schema, bits:u64)`. Define `E(n)[i] = (n / 256^i) mod 256`
and `D(b) = sum(b[i] * 256^i)`, for eight bytes. The source implementations in
`scalar.zig` satisfy `D(E(n)) = n` and `E(D(b)) = b` over their complete types:
the positional sum is at most `2^64-1`, and every encoded digit is a byte.

Both execution paths use the same raw arithmetic rule. The ordinary scalar
interface is the composition `decode -> raw rule -> encode`; faults are passed
through unchanged. Specialization removes the adjacent conversion operations.
The representation law therefore depends on the following frame operations:

- `read` packs a raw entry; `read_raw` decodes an ordinary scalar entry.
- `write` removes the corresponding raw entry; `write_raw` clears ordinary
  storage and old ownership before installing raw bits.
- `clear` removes both representations; `retain` applies the same live-key set
  to both maps. Raw scalars carry no owned guest resource.
- `to_public` materializes the raw map into ordinary guest bindings; `valid`
  independently rejects overlapping maps. Guest admission then checks the
  reconstructed schema, width, layout, liveness and ownership.

Hydration starts with ordinary bindings and an empty raw map, making every
admitted guest cut available to either realization. This is a rule argument
about these operations, not a universal claim inferred from benchmark samples.
`frame_tests.zig` challenges mixed writes, clears, pruning, old versions and
overlap. `scalar_tests.zig` compares arithmetic to Horos's independent scalar
oracle. `semantic_specialization_tests.zig` compares actual residual execution
and canonical states and counts removed packing work on dynamic inputs.

## Two checkpoint levels

`Resident.beginAdvance` selects one guest command; `Resident.pump` bounds base
work. A suspended pump is not a guest outcome. Only the actual published service
continuation exposes a guest cut. Recovery anchors retained during an unfinished
operation are validated but are not reported as its completed guest result.

`RuntimeCapsule.Kind.guest_cut` carries canonical guest state and permits checked
hydration into an independently approved realization. `outer_execution` carries
the exact base checkpoint, immutable initialization input, selected command,
command disposition and realization identity. It restores only the same artifact.
Both retain guest/outer revisions, exact dependencies and host provenance.

Restore checks canonical content, identities, command shape, guest admission and
the available mapped source phases before calling the trusted custody verifier.
The verifier authenticates the exact capsule and target, current owner scope and
one-time import. Candidate construction finishes before that custody claim; no
fallible allocation follows it. This verifier is an environmental obligation,
not a cryptographic protocol supplied by Kosmos.

## Nonadvancing switches

`runtimeBinding` returns the current artifact, guest revision, outer revision and
resident generation. `realize` checks that complete binding under the resident
gate, reconstructs the source, hydrates a private candidate and compares canonical
guest bytes. It allocates source and target capsules before calling `SwitchOwner`.
No runnable candidate handle escapes.

The host callback must approve the target and bind the operation to its actual
work, pending-control disposition and publication authority. It returns:

- `rejected`: discard the candidate and preserve the source.
- `committed`: install the candidate without further fallible work, retire the
  source, preserve the guest revision and invalidate prior local receipts.
- `uncertain`: retain both private states and fence ordinary resident operations.
  `resolveRealization` presents the same bytes to the durable owner; it must
  resolve or replay the same publication, never start another operation.

The expected environmental request identity is preserved because the guest
checkpoint is unchanged. Kosmos cannot determine whether a host has dispatched
that request; checking active/unknown delivery belongs to the enclosing owner.

## Evidence and physical limits

`check-native` includes the portable semantic suites and frozen native oracle;
`check-semantic-driver` covers artifact admission, recovery, capsule custody and
resident switching. `check-publication` retains the historical public byte,
large-state and allocator-failure obligations. `check-kernel` compares ABI3 native
and WASM boundaries and includes native-specialized to generic-WASM continuation.

The WASM qualification harness explicitly supplies a 128 MiB working arena.
The previous 8 MiB harness budget is insufficient even for preparation of the
authored evaluator. This is a physical cost increase; guest semantics and ABI3
formats do not change. Capacity-failure checks still lower arenas to zero or to
measured live usage. Native allocation counters are not RSS measurements.

These mechanisms do not by themselves establish Protean workspace integration,
bilateral mobility, all platform qualification, useful end-to-end specialization
economics or observed model effectiveness. Those require their owning integration
tests and measurements; the local capsule verifier tests use an in-memory owner.
