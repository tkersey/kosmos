# Repository-local releases: Kosmos

Status: implementation contract, not implemented automation. This document replaces the Kosmos portion of the proposed shared `align` / coordinated-stack-publication architecture. The implementation remains outstanding until the acceptance requirements below have executable evidence.

## Decision and ownership

Kosmos discovers eligible published Horos releases, proposes one ordinary Kosmos dependency-update PR, qualifies and reviews that candidate, and publishes only Kosmos. Protean independently discovers the resulting Kosmos release. Kosmos never writes Horos or Protean, publishes their releases, or coordinates a global transaction.

Use publish-before-consume. A successful unpublished Horos development commit is not an automatic dependency candidate. Existing pinned development inputs remain reproducible; bootstrap must not downgrade them to an older published release merely to adopt this policy.

No shared `align` executable, new `skills-zig` application, central controller, cross-repository dispatch, database, second dependency registry, or alignment-specific review engine is required. Put the refresh in existing repository-owned build/dependency machinery and keep workflow glue narrow.

## Existing authorities

`build.zig.zon` owns the Kosmos version and exact Horos commit/package binding. `package.json` mirrors the package version. Existing native generation owns build profiles and packaged runtime outputs. `.github/workflows/runtime-bundle.yml`, `docs/verification.md`, and `docs/executable-semantics.md` own qualification and execution/publication laws. Preserve all current requirements and `AGENTS.md` instructions.

The inspected baseline was commit `79384cc621269959e861f137278552b76a9d1fea`, package 9.1.0, exact Zig 0.17.0, and Horos `7d34f2c72e818665be4d519fde4f2cef9c986048`. These are historical inspection coordinates, not update targets. Re-read current source before implementation and preserve intervening work.

Package versions need not match upstream versions. ABI, protocol, wire, and state identities are separate; routine dependency work cannot rewrite them.

## Discovery and selection

Add a repository-local scheduled and manually dispatchable workflow. Poll upstream releases directly; no event delivery or central service is necessary for correctness. Schedule at an off-hour-boundary minute, with explicit opt-in for mutations and a local concurrency group. The schedule is best-effort eventual discovery, not an exact delivery promise.

Paginate discovery. Distinguish the currently selected input, latest observed publication, and newest admissible successor on approved upstream lineage. Resolve annotated tags to immutable commits and authenticate the release's source, package identity, qualification, and retained evidence. Do not trust API ordering, tag text, a release title, a checksum calculated from an arbitrary download, or an immutable-release flag alone. Reject drafts, unsupported prereleases, ambiguous identities, different contents under an existing version, unapproved histories, and automatic downgrades.

Tree-identical squash commits are source-equivalent, not missing source changes. That classification does not transfer transport digests, qualification, or review credit. Do not rewrite a valid selection solely to normalize its commit spelling.

Freeze one eligible Horos release before refresh. Discovery of a later release does not change an in-flight candidate. A blocked upstream release does not invalidate the previously accepted Kosmos selection.

## Local refresh

Provide one narrow operation taking a frozen, authenticated Horos selection. It does not independently select source, obtain merge credentials, or write GitHub state.

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

Discovery may be read-only, but PR writes, protected automatic promotion, and publication require explicit owner-controlled enablement. Creating this contract does not authorize credentials, repository administration, merging, releases, or installation. Do not modify installed runtimes, saved tasks, or retention bindings.

Implement tests for exact-source admission, malformed/colliding release identities, same-version different trees, tree-identical squash cases, mirror/generated-output mismatch, deterministic refresh/version preparation, base changes, frozen candidates, human edits/holds, duplicate wake-ups, uncertain writes, missing review evidence, skipped lanes, failed attempts, and immutable publication collisions. Keep new jobs within ten minutes without resetting existing qualification clocks.

Live authorized testing must exercise the real proposal, full review, protected merge, post-merge qualification, and local publication path. Fixture success is not deployed success. Demonstrate that Protean can discover the completed release and read its exact Horos binding without any cross-repository mutation by Kosmos.

Completion requires the implemented refresh, workflow, original review integration, protected promotion, local publication, and actual acceptance evidence. A detector, this contract, a draft PR, or an unexecuted workflow is not completion. Report implemented, tested, qualified, enabled, published, and installed states separately.
