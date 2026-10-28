# Executable guest semantics

The public guest facade runs `semantic/service.zig` as ordinary Horos code on
`base/session.zig`. The build emits `semantic-core.kar`; adding a guest image
does not rebuild the generic evaluator. The direct guest evaluator is fetched
from the immutable, hash-pinned
Kosmos `62279bce8e916e7fe613fe4575b3bc12e530596f` archive for qualification
and benchmarks only. No copied native guest engine remains in this source tree.

The resident pump continues every admitted outer operation after restore:
initialization, advance, observation, projection and finish. Its result is
`suspended`, an owned service `event`, or `closed`; callers release it with
`deinit`. Observation and projection preserve the guest revision. Resident reply
admission retains the actual published request identity and effect contract
under its exclusive mutation gate, including bounded submission. The driver
derives and retains the current binding from the actual request, checks every
supplied binding against it, clears it after successful advance submission, and
restores it on transaction rollback. Low-level Session replies use this same
owner. An unfinished operation rejects new controls before reading cut data,
including restoration before the first initialization cut.

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

Compiler policy `kosmos.source-lower/2` reconstructs generic and helper source
from the bound implementation. A specialized artifact carries its residual
source and finite specialization derivation. Horos reconstructs the trusted
frontend's lowering input and formal-parameter origins, then independently
checks the carried structural correspondence against the actual final image.
The evidence does not supply alternative generic source, helper source,
lowering input, or parameter bindings. Recovery-preserving lowering retains
general handler clauses when tail conversion has no checked origin transport;
source specialization and structural coalescing remain available.

## Representation and correspondence

Guest nodes and blobs live in persistent binary forests; frame bindings use
sparse Patricia maps. Source updates rebuild the affected paths. The base keeps
ordinary aggregate children as references, so these source paths remain shared
instead of eagerly serializing the entire tree. Exported bytes are materialized
only when demanded. Stable guest IDs and canonical PST3 projection remain the
public observation.

Large encoded aggregates use a bounded cache of 256 projection ranges keyed by
the exact source blob, schema, coordinate and operation. Hits still create the
same guest values and allocations. Collection first establishes live blobs,
then drops dead cache entries and remaps surviving keys. Public projection omits
the cache and hydration starts it empty; exact outer execution retains it.
Recovery validates the cache map, source blob/schema, slot and operation coordinate,
then recomputes retained ranges in coordinate order before accepting the machine.
Validation starts with an empty private cache and adds each original entry only after
its complete range matches the source. Collection traversal can reuse an already
verified prefix; supplied unchecked ranges never seed later checks. A matching byte
bound alone does not establish a range. The original machine remains unchanged.
Admitted caches contain at most 256 entries. Temporary ordering and verified-prefix
storage have the same bound; scalar traversal retains checked width arithmetic.
On a sequence miss, traversal can resume after the greatest retained earlier
coordinate with the same blob, schema and element operation. Backward reads and
collisions preserve these exact-key checks; the search adds no retained entries.
Repeated scalar skips use checked count-times-width arithmetic. Variable-width
skips retain their order and reuse one resolved schema descriptor. Zero counts
still avoid schema access; zero-width schemas avoid descriptor access.

After `blob_length` retires a backing of at least 64 KiB from the current frame,
the authored transition runs ordinary reachability collection. A surviving direct
alias avoids that trace; captured and indirect aliases remain tracing roots.
This releases dead large input at bounded active cuts as well as public suspensions.
Canonical checkpoint size is measured separately from physical retained storage.

Reconstruction traverses the table forest in chronological order. Node conversion
is fused with that traversal, and storage validation walks one ordered sequence;
neither repeatedly looks up and rebuilds every numeric ID. Table shape, frame and
reference-bound checks still run before the reconstructed state reaches guest
admission. The base also uses the known end of an admitted product or sum when
extracting its final field, avoiding another full parse of that subtree.

Frames use one sparse map whose entry is either an ordinary guest value or a raw
scalar `(schema, bits:u64)`. The map owns key uniqueness and the tagged entry
contains exactly one representation. Define `E(n)[i] = (n / 256^i) mod 256`
and `D(b) = sum(b[i] * 256^i)`, for eight bytes. The source implementations in
`scalar.zig` satisfy `D(E(n)) = n` and `E(D(b)) = b` over their complete types:
the positional sum is at most `2^64-1`, and every encoded digit is a byte.

Both execution paths use the same raw arithmetic rule. The ordinary scalar
interface is the composition `decode -> raw rule -> encode`; faults are passed
through unchanged. Specialization removes the adjacent conversion operations.
The representation law therefore depends on the following frame operations:

- `read` packs a raw entry; `read_raw` decodes an ordinary scalar entry.
- `write` and `write_raw` replace the single entry and remove its old ownership;
  an owned ordinary value establishes its new owner. Raw scalars carry no owned
  guest resource.
- `clear` removes the entry; `retain` selects the live keys from this one map.
- `to_public` traverses the map in key order and materializes raw entries while
  emitting ordinary guest bindings. `valid` independently rejects malformed map
  structure, including duplicate keys. Guest admission then checks the
  reconstructed schema, width, layout, liveness and ownership.
- Continuation cloning walks frame bindings directly in key order, retaining the
  reference accumulator's prefix and repeated occurrences. Reference rebasing
  applies the existing NodeRef map once, retains raw scalar tags and all 64 bits,
  and rebuilds only changed leaves and their ancestors. Unchanged subtrees, frame
  metadata and the lexical owner sequence are reused. Nonempty mappings still
  require a full retained-binding traversal. Public projection and the independent
  clone-phase validator remain separate from these operations.

Hydration wraps each admitted ordinary binding in the ordinary-value variant, making every
admitted guest cut available to either realization. This is a rule argument
about these operations, not a universal claim inferred from benchmark samples.
`frame_tests.zig` challenges mixed writes, clears, pruning, old versions and
duplicate-key trees. The former cross-map overlap state has no representation in
a valid single map. `scalar_tests.zig` compares arithmetic to Horos's independent scalar
oracle. `semantic_specialization_tests.zig` compares actual residual execution
and canonical states and counts removed packing work on dynamic inputs.

## Two checkpoint levels

`Resident.beginAdvance` selects one guest command; `Resident.pump` bounds base
work. A suspended pump is not a guest outcome. Only the actual published service
continuation exposes a guest cut. Recovery anchors retained during an unfinished
operation are validated but are not reported as its completed guest result.
The published service continuation carries one committed state. The preceding
command input remains available during the transition and publication handoff,
then retires when the new state becomes the service continuation. Native
publication transactions retain their own rollback custody until commit.
The service returns its retained state when finishing a terminal guest. This keeps
the recovery parameter live through its last ordinary base return, including
bounded cuts after the terminal-status check. The driver reports `closed` only
after that return; it does not serialize or expose the private return value.
The capsule regression transfers every bounded finish cut for completed, failed
and cancelled guests under both generic and specialized realizations, retiring
the source owner before each exact-custody restore.

`RuntimeCapsule.Kind.guest_cut` carries canonical guest state and permits checked
hydration into an independently approved realization. `outer_execution` carries
the exact base checkpoint, initialization input while initialization is unfinished,
selected command, command disposition and realization identity. It restores only
the same artifact.
Both retain guest/outer revisions, exact dependencies and host provenance.
Initialization input is released after its first committed cut; rollback retains
it until that commit. Later capsules use the committed evaluator state and omit
the dead input. Older capsules that carry it are admitted without retaining it.

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

## Semantic source and checked construction

`RuntimeCompiler.exportSource` reconstructs and checks the actual selected
artifact before returning its source bundle. The bundle distinguishes the
approved root, selected module, guest scope, recovery interfaces and four helper
images. It does not substitute the packaged generic module for a selected
realization. Horos `source.slice.extract` admits the complete module, extracts
the selected function's dependency closure and can require an effect-free slice.
The resulting source is ordinary editable Horos data.

`RuntimeCompiler.deriveRecord` packages a proposed module and finite relation
steps as an admitted candidate. `validateAgainst` separately checks it against
the owner-selected ancestor. The new artifact and lowering contracts are
`kosmos.semantic-artifact/3` and `kosmos.source-relation/1`; historical `/2` decoding
and verification retain their original meaning. A candidate cannot supply its
own approved root or convert successful compilation into validation.

The Horos relation checker reconstructs scalar simplifications, closed pure
inlining, private product coordinate permutations, catalog relocation and
existing specialization steps. It compares complete successor modules and
rejects unsupported changes. Kosmos then derives recovery mappings and checks
the final runtime and helper images against that source. Intermediate evidence
uses reconstructible canonical byte deltas; every reconstructed step remains
subject to the same checker. Resource exhaustion is not approval.

Evidence decoding retains each reconstructed byte buffer with its decoded source
module in the validation arena. Ordinary relation fields reuse their decoded
storage; encoded specialization proofs still use the Horos record decoder.
This avoids copying an already decoded source module for every ordinary relation
step. Decoding and independent relation validation retain their existing work
budgets, canonical-delta checks and complete source comparisons.

`RuntimeTransformation.scalar` and `.layout` construct ordinary Horos producer
programs. Their inputs contain source records and selected objectives; their
outputs contain candidate source and relation records. Native compilation and
validation consume those outputs without choosing replacement code. Producer
execution, candidate admission, validation and retained-state realization are
separate operations.

`RuntimeExperiment` runs an unapproved candidate without live guest custody.
Its bounded pumps retain initialization, execution, observation and projection
progress. The enclosing owner must independently execute its approved reference,
admit and compare complete guest state, observation and work, and publish only
the reference successor. Finite agreement does not authorize an ordinary
realization switch. Real guest cancellation remains the reference owner's duty.

## Views and isolated interpretations

Guest views default to metadata. `RuntimeViews.captureDetailed` accepts explicit
node, field and blob-range disclosure, reports value coverage, and includes the
schema information needed to interpret authorized values. Borrowed PST3 decoding
avoids copying an entire payload merely to inspect metadata; returned projections
own their disclosed data. Outer-capsule inspection exposes the selected
runtime's private execution state under a separate binding; it is not a
committed guest cut.

Complete guest snapshots require explicit `snapshot` disclosure together with
all graph nodes and all node values. The returned optional state owns its data
and reconstructs the exact canonical checkpoint under the same binding. Partial
scopes, bounded blob slices and outer-capsule snapshot requests are rejected.
The default path carries no snapshot and makes no full-payload copy. Disclosing
this state supplies analysis data; it grants no restore, execution or custody right.

`RuntimeAnalysis.interpretation` builds an ordinary pure driver with an explicit
sequence of assumed replies, request history, guest-work allowance and stopping
disposition. It can start from admitted arguments or an admitted snapshot.
Unavailable replies remain unavailable; partial execution returns state for a
later hypothetical continuation. Generated source may instead compose disclosed
pure functions into its own interpretation. Neither source admission nor an
analysis result grants guest acquisition, settlement or custody.

The legacy `hypotheticalReply` helper stops before applying a reply when its
guest-work allowance is exhausted. The multi-reply interpretation applies supplied
replies at pending requests without consuming guest work, including a retained
request with zero allowance; further guest steps still require remaining allowance.

## Consumer-aware program construction

`RuntimeTransformation.consumer` authors a pure Horos program whose
`ConsumerInput` contains an immutable source module and selected consumer site.
It emits the existing `RecordProposal`: a candidate plus two finite
`inline_call` steps. Horos's independent source relation checks the actual
records, fresh bindings, strict argument evaluation and complete successor.
The producer supplies no trusted purity or consumer-identity flags. This path
constructs a new guest program; it grants no live checkpoint or realization
transport for the original guest.

The shared product-to-Boolean example executes the producer itself on Kosmos,
decodes its proposal, independently validates it, and executes both callers on
dynamic inputs. Structural lowering removes two call entries from the selected
route (three to one), while total transitions increase from eleven to thirteen
because strict finite bindings remain. The other caller stays at three calls
and eleven transitions. The existing semantic compiler already optimizes both
versions; no additional backend speedup is claimed. In this sample, proposal
construction uses 4,923 or 4,749 base transitions, with 1,299 input bytes and
4,818 output bytes.

Horos's logical-context examples also run through the ordinary Session owner.
They retain explicit Reader values across yield and fresh-instance restore,
restore the outer scope, isolate branch annotations, and give cleanup the
snapshot retained at protection establishment. For counts zero, four and
twelve, replacing the current frame keeps checkpoint size at 109 bytes;
retaining snapshots produces 109, 209 and 410 bytes. Graph/control and requested
allocator bytes are reported separately. These finite observations establish
neither constant physical memory nor persistent sharing.

## Evidence and physical limits

The pure hypothetical-reply example admits argument and reply bytes against the
embedded guest schemas before using them. Malformed values fail the analysis;
valid assumptions remain explicitly hypothetical and confer no live authority.
Its value parser is ordinary Horos code, checked against Horos's independent
native admission rules, and does not add a native service to the example.

The source package also retains `src/semantic-core.kar` for authenticated
downstream consumers. `src/semantic_packaged.zig` checks its exact source,
compiler-package, Zig-version and content bindings before emitting those bytes.
This avoids recompiling the unchanged host generator for each consumer. The
fingerprints select previously checked content; they are not translation proof.
Ordinary runtime builds use the retained core by default.
`check-semantic-driver` compares the retained bytes with a freshly compiled,
admitted and independently validated result.

After changing the semantic source, run `zig build semantic-artifact
-Doptimize=safe`, copy `zig-out/semantic-core.kar` to `src/semantic-core.kar`,
update the source/content/compiler bindings in `semantic_packaged.zig`, and run
`zig build check-semantic-driver -Doptimize=safe`. The downstream emitter fails
closed on stale bindings and prints the current digests to aid that update.
Changing a fingerprint without rebuilding cannot pass the byte comparison.

`check-native` runs the behavioral and lifecycle regressions on the public
semantic runtime, plus differential comparisons with the immutable native oracle;
`check-semantic-driver` covers artifact admission, recovery, capsule custody and
resident switching. `check-publication` retains the historical public byte,
large-state and allocator-failure obligations. `check-kernel` compares ABI3 native
and WASM boundaries and includes native-specialized to generic-WASM continuation.

The shipped WASM default and qualification harness allow 128 MiB of working
allocation. The kernel initially reserves at most 1 MiB of working backing and
grows physical memory as needed; the allowance does not eagerly reserve 128 MiB.
The previous 8 MiB harness budget did not cover the complete qualification
workload. This is a physical cost increase; guest semantics and ABI3
formats do not change. Capacity-failure checks still lower arenas to zero or to
measured live usage. Native allocation counters are not RSS measurements.

[Semantic economy measurements](semantic-economy.md) report matched native,
bootstrap, generic, specialized and instrumented runs, including construction,
validation, publication, restore, memory and amortization costs.

These mechanisms do not by themselves establish Protean workspace integration,
bilateral mobility, all platform qualification, useful end-to-end specialization
economics or observed model effectiveness. Those require their owning integration
tests and measurements; the local capsule verifier tests use an in-memory owner.
