# Native checkpoint predecessor witness

Captured before the decoder-policy change, using Zig 0.17.0, ReleaseSafe,
Horos `19b607b8d0eecdb60abc28399acfa1e577d79049`, and Kosmos
`42825493ae0db255c9e1c0fddb245020707dbce7` on native macOS arm64.

`native_decode.zig` retains the exact 52-byte BPI3 image, source generator,
payload generator, checkpoint lengths, and SHA-256 hashes. The image's raw
SHA-256 is `bfabd432f55de159785a74248dc6192583da745d5c4cd3069a0b79fbabdbbfdb`.
These raw object hashes are distinct from domain-separated program and
pending-state identities.

| Payload bytes | PST3 bytes | Original public restore |
| ---: | ---: | --- |
| 1,048,576 | 1,048,658 | Completed with exact original encoded argument |
| 67,108,608 | 67,108,692 | `Capacity` after successful custody transfer |
| 68,157,440 | 68,157,524 | `Capacity` after successful custody transfer |

Both large states passed diagnostic graph decoding with a caller-selected
256 MiB budget. The current regression requires canonical native restoration
and exact completion for every case, while preserving rejection under an
explicit 64 MiB budget. It regenerates large buffers sequentially and checks
their frozen predecessor hashes instead of committing giant binary fixtures.

Additional current-source witnesses grow a 34 MiB input to 68 MiB before
checkpoint publication, and park 65 MiB in a multi-shot continuation before
transfer. The latter verifies an actual template in PST3, restores it through
the public Resident API, and checks two branch activations with the exact result.
These are positive regression coverage, not additional frozen predecessor probes.
