# Repository-local releases: Kosmos

This runbook describes the implemented repository-local preparation, proposal, owner-review, protected promotion, and publication workflows. Automation defaults to off. Local adapter and native checks establish only their tested scope; full qualification of the final committed source, original serial owner reviews, and live commissioning remain separate acceptance requirements. No release, installation, or owner enablement is implied.

## Decision and ownership

Kosmos discovers eligible published Horos releases, proposes one ordinary Kosmos dependency-update PR, qualifies and reviews that candidate, and publishes only Kosmos. Protean independently discovers the resulting Kosmos release. Kosmos never writes Horos or Protean, publishes their releases, or coordinates a global transaction.

Use publish-before-consume. A successful unpublished Horos development commit is not an automatic dependency candidate. Existing pinned development inputs remain reproducible; bootstrap must not downgrade them to an older published release merely to adopt this policy.

No shared `align` executable, new `skills-zig` application, central controller, cross-repository dispatch, database, second dependency registry, or alignment-specific review engine is required. Put the refresh in existing repository-owned build/dependency machinery and keep workflow glue narrow.

## Existing authorities

`build.zig.zon` owns the Kosmos version and exact Horos commit/package binding. `package.json` mirrors the package version. Existing native generation owns build profiles and packaged runtime outputs. `.github/workflows/runtime-bundle.yml`, `docs/verification.md`, and `docs/executable-semantics.md` own qualification and execution/publication laws. Preserve all current requirements and `AGENTS.md` instructions.

The inspected baseline was commit `79384cc621269959e861f137278552b76a9d1fea`, package 9.1.0, exact Zig 0.17.0, and Horos `7d34f2c72e818665be4d519fde4f2cef9c986048`. These are historical inspection coordinates, not update targets. Operational decisions always re-read current source and preserve intervening work.

Package versions need not match upstream versions. ABI, protocol, wire, and state identities are separate; routine dependency work cannot rewrite them.

## Discovery and selection

`Repository preparation` polls upstream releases directly on its own schedule and manual dispatch; no cross-repository event delivery or central service is necessary for correctness. It runs at minute 17 with explicit opt-in and a local concurrency group. The schedule is best-effort eventual discovery, not an exact delivery promise.

Paginate discovery. Distinguish the currently selected input, latest observed publication, and newest admissible successor on approved upstream lineage. Resolve annotated tags to immutable commits and authenticate the release's source, package identity, qualification, and retained evidence. Do not trust API ordering, tag text, a release title, a checksum calculated from an arbitrary download, or an immutable-release flag alone. Reject drafts, unsupported prereleases, ambiguous identities, different contents under an existing version, unapproved histories, and automatic downgrades.

Tree-identical squash commits are source-equivalent, not missing source changes. That classification does not transfer transport digests, qualification, or review credit. Do not rewrite a valid selection solely to normalize its commit spelling.

Freeze one eligible Horos release before refresh. Discovery of a later release does not change an in-flight candidate. A blocked upstream release does not invalidate the previously accepted Kosmos selection.

## Local refresh

`kosmos-refresh prepare` takes one frozen, authenticated Horos selection. It does not independently select source, obtain merge credentials, or write GitHub state.

Acquire the exact source in a credential-restricted workspace. Authenticate complete Git paths, blobs, executable modes, and tree identity before accepting newly calculated transport or inventory metadata. Preserve existing link, traversal, special-file, duplicate-path, and changing-file protections. Obtain package identity with the exact admitted Zig compiler; do not fabricate a package hash.

Update the Horos manifest binding and required generated evaluator, build-profile, and source-identity outputs as one candidate using existing public generation paths. Use a semantic parser or bounded writer for manifests, not regex-only version/URL replacement. Verify generated output before proposing it; reject unexpected paths or changes outside the declared mechanical scope.

Prepare any required Kosmos package-version change in this same PR, before final hashing and qualification. Keep `package.json` in agreement. Use an explicitly approved local compatibility/version rule, preserve an already approved pending version, and never increment again merely because the workflow repeats. A breaking migration blocks routine automation and becomes ordinary implementation work; passing compilation alone is not a compatibility declaration.

A local/CI coherence check verifies version mirrors, the exact Horos binding/package identity, toolchain requirements, and generated outputs from admitted local inputs. It must not require freshness discovery for an ordinary build. Coherence is additional to, not a replacement for, full native/runtime/package qualification.

## One ordinary update PR

Maintain one automation-owned dependency/version-preparation PR in this repository, assigned to `tkersey`. Its body records the frozen upstream identities, compatibility/version decision, generated scope, and actual blocker or outstanding gate.

Use conditional writes and inspect uncertain outcomes before retry. Repeated discovery of the same state is a no-op. Do not overwrite human branch edits, reopen a manually closed candidate, or re-enable auto-merge after an owner hold. Freeze the head during qualification/review; an updated base or material input requires a regenerated candidate and fresh affected evidence.

Full Actuating/CAS execution and adjudication remain authoritative, including auxiliary reviews, applicable focused-file obligations, model/reasoning parity, and five consecutive credited standard reviews on an unchanged candidate. Missing unattended execution or authenticated closeout wiring is an explicit implementation blocker. No script-local clean counter, PR label, prose verdict, process exit, or fabricated receipt substitutes for the original evidence.

Use protected auto-merge only after owner enablement, effective protection verification, allowed-diff admission, full qualification, full credited review, and thread resolution. Preserve required human approvals until explicitly reconfigured by the owner. Never push to `main` or use administrator bypass.

Preserve every existing runtime/native/WASM/browser/source/consumer lane, aggregate, TigerStyle requirement, and the existing runtime budget. Incomplete, skipped, neutral, diagnostic, wrong-subject, or timed-out observations do not pass admission. Repeated test attempts and empty commits must not launder a failed candidate into a success.

## Local publication

After merge, qualify the actual landed source again under the existing post-merge contract. Then, when separately enabled, publish only Kosmos. Its frozen Horos dependency must already have a matching qualified publication. Do not publish or patch Horos on Kosmos's behalf.

Reuse exact tested runtime/source artifacts and existing distribution channels. The current qualification retains a tested runtime package; publication must authenticate that artifact's run, subject, final contents, and required evidence rather than rebuilding under release credentials. Any packaging/signing transformation that changes executable bytes requires verification of the final distributable bytes.

Expose the exact Horos dependency in derived release evidence, together with Kosmos source/tree/version, final asset identities, and qualification/review references. Source manifests remain the dependency authority. Release evidence is not a second hand-edited lock and does not claim its own self-referential digest.

A trusted publisher runs separately from candidate code and has only local authority. Candidate computation/review jobs have no branch-write or release credentials; source checkouts disable credential persistence. Pin accepted control code and actions; do not execute untrusted caches with publisher credentials.

Re-fetch tags and assets after publication. Identical existing publication is a no-op; different source or bytes under the same tag/asset name is a block. Do not overwrite, retag, delete valid upstream releases, or create a global rollback transaction. A failed Kosmos release simply remains locally incomplete; Protean retains its accepted combination.

## Enablement and acceptance

Discovery may be read-only, but PR writes, protected automatic promotion, and publication require explicit owner-controlled enablement. Installing these workflow definitions does not authorize credentials, repository administration, merging, releases, or installation. Do not modify installed runtimes, saved tasks, or retention bindings.

The release test suite covers exact-source admission, malformed/colliding release identities, same-version different trees, tree-identical squash cases, mirror/generated-output mismatch, deterministic refresh/version preparation, base changes, frozen candidates, human edits/holds, duplicate wake-ups, uncertain writes, missing review evidence, skipped lanes, failed attempts, and immutable publication collisions. Keep new jobs within ten minutes without resetting existing qualification clocks.

Live authorized testing must exercise the real proposal, full review, protected merge, post-merge qualification, and local publication path. Fixture success is not deployed success. Demonstrate that Protean can discover the completed release and read its exact Horos binding without any cross-repository mutation by Kosmos.

Acceptance requires the implemented refresh, workflow, original review integration, protected promotion, local publication, and actual execution evidence. A draft PR or an unexecuted workflow does not establish live commissioning. Report implemented, tested, qualified, enabled, published, and installed states separately.

## Implemented native preparation and retained qualification

`zig build build-release-tools -Doptimize=safe` builds the repository-owned
`zig-out/bin/kosmos-refresh`. `prepare ZIG BASE_REPO INPUT_JSON OUTPUT_DIR`
accepts a frozen `kosmos-refresh/v1` input containing `baseCommit`, `baseTree`,
`version`, and `horos` with `commit`, `tree`, `url`, `packageIdentity`,
`sourceArchive`, `sourceRepository`, `sha256`, and `size`. Paths are absolute.
The caller must authenticate the upstream publication before this operation;
the helper independently verifies its archive against the selected Git objects.
It runs with isolated Git/compiler state and one 600-second operation deadline.

Preparation writes a new output directory only after native generation and
coherence succeed. The output contains `source/` and `result.json`. The only
mechanical paths are `build.zig.zon`, `package.json`, `src/root.zig`,
`src/embedding/index.mjs`, `src/semantic-core.kar`, and
`src/semantic_packaged.zig`. Exact semantic projections reject unrelated changes
even within those paths. All four version mirrors must agree. Existing build
profiles and their historical boundary metadata are checked and preserved.
A repeated accepted selection has an empty `changed` array; existing output
directories are never overwritten.

`check ZIG SOURCE_DIR` performs local coherence without release discovery.
`zig build check-release-tools check-release-coherence -Doptimize=safe` exercises
native rejection cases and the current source. `zig build check-source-package
release-source -Doptimize=safe` runs one shared full-source producer and public
native consumer, then retains `zig-out/release-source/source.tar` and
`source.json`. The receipt includes all Git paths/blobs/modes, actual source and
package identities, and version/compiler/Horos facts parsed from the manifest.
The requested Git head is an explicit build input and is checked again by the
native producer.

The existing nine runtime lanes, TigerStyle job, runtime budget gate, and complete
gate remain required. The consumer lane additionally runs native release tests,
coherence, the source producer, and the repository-local JavaScript boundary
tests. Runtime work still has the original 600-second aggregate budget;
TigerStyle remains independently required and exempt from that aggregate.

The portable package test retains the exact npm archive it extracted and tested,
the extracted `kosmos-kernel.wasm`, generated `kernel-profile.json`, and
`runtime.json` linking their byte identities and profile. CI uploads these four
files and both native source files as six raw Actions artifacts after successful
checks, with 14-day retention. Publication must use these retained bytes; it
does not run a second packaging operation under release credentials.

`admitKosmosQualification` requires the unique original workflow run and attempt,
all twelve successful jobs, their required executed steps, matching native
platform/source/profile, original clocks and aggregate budget, and authenticated
artifact transport. It checks the final npm/WASM/profile digests against the
portable test receipt. Expired evidence, skipped steps, duplicate runs, retries,
and changed payloads block admission.

`assemblePublishedKosmos` authenticates exactly one existing Horos publication
through the local release admission boundary. Assembly matches its exact commit
and package identity to the native manifest facts, links the supplied manifest
and build profile to their Git blobs, derives the Kosmos source/version/dependency
record, and hashes the retained final payloads. The adjacent producer fixtures
are deliberately unpublished compatibility evidence and cannot substitute for
publication authentication.

These boundaries have local native and adapter verification. Final committed
full-source TigerStyle, complete platform qualification, actual workflow artifact
admission, original review closeout, and enabled proposal/promotion/publication
remain separate acceptance requirements. No live release or installation is
established by these local checks.

The build invokes the separate `source-build` operation for regenerable build
outputs. Zig's always-run steps may reuse an output directory when source or
producer contents change. This operation holds a nonblocking operating-system
file lock for verification, consumption, and retention; competing writers fail
with `BuildOutputBusy`. Both replacement files are staged after the full consumer
succeeds, and symlink/special destinations are rejected. A failed write cannot
qualify a mixed archive/receipt pair because receivers recheck their byte binding
and workflows upload only on success. The ordinary `source` operation retains
immutable collision rejection.


### Publication of qualified Kosmos artifacts

The repository-local publisher runs on accepted main after original qualification
and owner review. It also observes its own hourly schedule. Both controls must
permit publication: REPOSITORY_AUTOMATION is propose or promote, and
RELEASE_PUBLICATION_ENABLED is true. Defaults are off and false.

The workflow compiles the accepted native manifest parser before introducing
credentials. A read-only App token admits the original landed qualification,
review history, exact final artifacts, and completed Horos publication.
It selects the dependencies already recorded in this source. An unrelated newer
release cannot replace them. Missing matching publication is a concrete blocker.

The local commands are:

```sh
node tools/release/kosmos-publication-runner.mjs prepare "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$OUTPUT" "$OBSERVER_IDENTITY"
node tools/release/kosmos-publication-runner.mjs publish "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$OUTPUT" "$PUBLISHER_IDENTITY"
```

Preparation seals the original source archive, inventory, tested runtime package and WASM artifacts
with the original qualification, reviewed publication boundary, landing mapping,
owner closeout, and authenticated original review artifact envelopes. It records
compiler, publisher Node, and reviewer binary identities separately. It neither
rebuilds artifacts nor transfers executable qualification across equal Git trees.

The trusted workflow attests the finalized record and payloads with pinned
GitHub artifact attestation tooling, then obtains a separate repository-local
publication token. The writer verifies the expected signer and recomputes the
admission from original observations before staging and before publication.
Only missing identical assets are uploaded. Conflicting tags, drafts, or bytes
remain untouched. Publication requires immutable-release protection and finishes
by checking the platform release attestation, source tag, and every asset.
A matching completed release is a verified no-op, without a bookkeeping commit
or another version bump. An interrupted matching draft resumes from observed
missing assets; changed source or expired original evidence blocks recovery.

The GitHub runtime archive does not imply npm publication.
Live App-created PRs, protected merging, authenticated Actions model review,
immutable publication and interrupted-write recovery require an owner-approved
commissioning environment; local adapter tests do not establish those effects.

### Native preparation and ordinary proposal operation

`Repository preparation` observes its own hourly schedule and local qualification
and owner-review completions. It runs only when `REPOSITORY_AUTOMATION` is
`propose` or `promote`. Its accepted-main tool reads the committed ZON manifest,
admits published Horos records, selects a forward compatible successor, and
combines that patch impact with the original reviewed Kosmos publication boundary.
A pending higher approved version is preserved. A selected development pin ahead
of published Horos releases is never downgraded. A new major or breaking upstream
migration requires ordinary implementation and review.

The preparation job compiles its exact accepted native tool before obtaining an
App observer token. Native code runs inside the required network-isolated
bubblewrap sandbox under the scoped AppArmor profile, with no write credential
or host credential environment. It retains the exact six generated source files,
original result, manifest/prepare/check stdout and stderr, compiler and tool
identities, original admitted dependency record, and own version decision.
The workflow uploads a generation-start artifact before native generation.
An existing original preparation is reused; an interrupted or failed equivalent
generation remains held until its original evidence is recovered. Deleting or
expiring an artifact does not authorize another invocation.

`Repository automation` runs separately after preparation completes. It uses
only authenticated original preparation artifacts, validates exact native file
bytes against the proposed Git tree, and creates or advances the one ordinary
`automation/dependency-release` PR, assigned to `tkersey`. It does not regenerate
candidate source. The App writer token is minted only after the accepted native
manifest reader is compiled. Reads of native manifest data remain sandboxed.

The exact local entry points are:

```sh
node tools/release/kosmos-preparation-runner.mjs plan "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$OUTPUT" "$OBSERVER_IDENTITY"
node tools/release/kosmos-preparation-runner.mjs generate "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$OUTPUT" "$OBSERVER_IDENTITY"
node tools/release/kosmos-automation-runner.mjs "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$WRITER_IDENTITY"
```

The workflow owns the original run ID and the start/result artifact uploads;
calling a local command alone does not create authenticated Actions evidence.
The two workflows use independent serialized concurrency groups with cancellation
disabled and retain the 600-second job ceiling. Native generation also has a
shared 600-second process deadline with group cleanup. Required qualification
and the owner model's original policy and review counts remain unchanged.

Promotion uses the original successful qualification and exact owner closeout,
checks effective branch protection, and uses the normal protected rebase merge
operation for an already `MERGEABLE/CLEAN` PR with `expectedHeadOid`.
Required checks and human approvals remain mandatory; no administrative bypass
is used. An uncertain merge response requires exact landing readback.
`propose`, `off`, a draft, or `automation-hold` cancels automation-owned pending
auto-merge. Failed qualification, unresolved review, stale bases, edited heads,
and unavailable original evidence hold the proposal. An admitted successor
requires closure of the original epoch. Automation never treats an owner closure
or manually disabled auto-merge as permission to resume. After reopening and
removing a hold, the repository owner must post this fresh, unedited exact comment:

```text
/repository-automation resume FULL_CURRENT_HEAD_SHA
```


A completed candidate stays frozen while its base remains current. After the base
advances, its authenticated closed epoch permits a fresh candidate and fresh
qualification/review. If a branch update succeeded before the PR description
update, the writer authenticates the described predecessor and actual successor
independently, then finishes only the missing metadata update. Further base
movement does not authorize another source transition during that recovery.
Unknown source edits, altered metadata, or unavailable original evidence hold
recovery. Branch updates use atomic expected-head checks; PR metadata uses
before/after observations and has no claimed atomic conditional-edit guarantee.
Historical closure/reopen and hold-label removal still require explicit owner
resume; removing the hold alone does not grant authority.

The owner input retains compact original preparation provenance, including every
non-file byte and the original run, job, workflow, and artifact identities.
Published original review evidence retains that same input. After the native
artifact expires, the reader hydrates the six file payloads from the exact
reviewed Git head and verifies the reconstructed original artifact digest and
size. It never reruns historical native code. Inputs that exceed the bounded
owner context fail before review starts and require recovery of bounded original
evidence. Unpublished evidence without a recoverable original remains blocked.
