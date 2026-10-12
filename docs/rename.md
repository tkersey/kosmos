# World → Kronos → Kosmos

Use the `kosmos` Zig module, `-Dhoros-source`, `@tkersey/kosmos`,
`bin/kosmos.mjs` and newly built `kosmos-kernel.wasm`. The JavaScript error
class is `KosmosHostError`. Boundary and Agent are now Horos and Protean.
Kronos was an intermediate product name; Kosmos is the current name.
No legacy source aliases or duplicate executables are installed.

ABI 3 export strings `world_*`, `WORLD_*` error codes, the
`world-kernel-inspection/v3` record format, Horos's `boundary.*` hash domains,
and all binary grammars and numeric tags are unchanged. Local Zig entry names
are independent of their fixed WASM export strings. Copyright and adapted-source
attribution retain their original spelling.

The existing `world-runtime-bundle/v1` verifier still binds the original
World 6.0.0 profile, `boundary` profile field, repository/package names and
`runtime/world-kernel.wasm` / `runtime/bin/world.mjs` members. Its fixtures
exercise that historical contract. Published assets and tags are untouched;
this does not certify renamed source as an old release. The current optional
JS package is built and checked with its matching new kernel.

Zig 0.17.0 derives the Kosmos name checksum `da7fbe49`; the lineage ID
`074dc2bd` is unchanged. Kosmos 7.0.0 marks the public module, package,
executable and error-class naming break from World 6.0.0. Package hashes are
computed by Zig; the portable formats and ABI 3 remain unchanged.
New scratch and output locations use Kosmos names. No old user state is discovered,
moved or deleted. Existing saved tasks retain their original build bindings;
use the original pinned build where restoration is incompatible.
