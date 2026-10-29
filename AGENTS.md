# Working on Kosmos

Read [TigerStyle for Kosmos](docs/tiger-style.md) before changing Zig code.
Preserve the execution, ownership and publication laws in [verification](docs/verification.md)
and [executable semantics](docs/executable-semantics.md).

Use exact Zig 0.17.0. Run the affected native qualification roots and the TigerStyle
full-source gate against the committed candidate. Every required check must finish
successfully; an interrupted, skipped or inconclusive run leaves verification outstanding.

Express intent through names, types, ownership and operations. Do not add explanatory
comments in source, tests or examples. Keep mandatory legal notices and machine directives.
