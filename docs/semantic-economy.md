# Semantic economy measurements

Measured 2026-10-17 on Apple M2 Pro, macOS 27.2 (26B5112a), Zig 0.17.0, safe optimization. Runtime sources: Kosmos host facade `1df63be7e42b015a763a2dba122a98494f3b8f1f`, semantic source `cd73df16c3b9d3b0f3920fffa9c3d4a5ee71525cae6782f672e021d66da6ccb7`, Horos `592eb0839326f2d8a423b59ce2746ab18ef5136a`. The Kosmos source identity binds the authored implementation and compiler before this report is generated. This measurement used a separate benchmark invocation after complete qualification; no other session-owned qualification or review process was active. These are local samples, not tail-latency or platform-independent claims.

Reproduce with `zig build bench-semantics -Doptimize=safe`. Select one workload with `-Deconomy-workload=scalar_chain`. Every measured realization is checked against the independent direct-native trace, canonical checkpoints and outcomes for the same inputs and controls. The direct-native and bootstrap evaluators are verification dependencies only, fetched from immutable Kosmos `62279bce8e916e7fe613fe4575b3bc12e530596f` with package identity `kosmos-8.0.0-vcJNB7_PDwCsxCmIN8VIVZsi9fW8qHX7Y5xesXeS6Kn5`. They retain that historical implementation and storage; no copied current engine supplies the reference. The reference shares the selected Horos admission dependency, so this comparison is independent execution evidence, not independent admission evidence.

Each family has three input samples. Generic, specialized and instrumented base execution each have three repetitions per input (nine observations); the direct native and bootstrap paths have one per input. Fixed handler and multi-shot programs vary their prescribed external responses where applicable. Dynamic loops use 16/32/48 iterations; cleanup uses 8/16/24 scopes; retained byte payloads use 1/8/64 KiB. Scalar inputs are 41/60/79; the chains contain 24 and 96 add/xor pairs on that dynamic input. The larger chain extends the original ten-workload suite; all original workloads and their inputs remain.

## Execution

Median milliseconds. This interval includes guest execution and its service events; explicit result observation, guest projection, restore and outer serialization are timed separately.

| Workload | Direct native | Generic bootstrap | Generic base | Specialized base | Instrumented base |
| --- | --- | --- | --- | --- | --- |
| scalar | 0.004 | 2.228 | 0.938 | 0.949 | 0.946 |
| scalar_chain | 0.016 | 84.207 | 19.130 | 19.024 | 19.050 |
| scalar_chain_large | 0.053 | 729.954 | 80.948 | 84.598 | 80.391 |
| dynamic_loop | 0.031 | 147.409 | 47.717 | 42.761 | 47.765 |
| structured | 0.006 | 4.424 | 1.716 | 1.588 | 1.719 |
| repeated_calls | 0.054 | 339.982 | 77.213 | 70.574 | 77.458 |
| higher_order | 0.006 | 4.060 | 1.451 | 1.416 | 1.453 |
| handlers | 0.045 | 197.931 | 36.634 | 36.902 | 36.627 |
| multi_shot | 0.037 | 57.600 | 14.959 | 16.627 | 15.072 |
| long_cleanup | 0.410 | 1157.127 | 199.364 | 387.991 | 200.300 |
| retained_bytes | 0.021 | 13.426 | 3.472 | 3.490 | 3.472 |

Specialization removes repeated descriptor interpretation and scalar packing, as independently exercised by `semantic_specialization_tests.zig`. The specialized execution median was lower in these samples for `scalar_chain`, `dynamic_loop`, `structured`, `repeated_calls`, `higher_order`. These timing differences describe these inputs and this execution profile; they do not establish universal speedup.

## Construction and artifacts

Construction and independent source/translation validation are separate. Peak bytes below are requested allocator bytes from construction, excluding allocator metadata and RSS. Construction, preparation, execution and restore have distinct allocation domains; their peaks must not be summed.

The generic artifact is 231,838 bytes, SHA-256 `c3be797414210c55c2ea639a8c5cf8494c5b118a82ffc7b5836832eeb86e940b`, source identity `cd73df16c3b9d3b0f3920fffa9c3d4a5ee71525cae6782f672e021d66da6ccb7`. Admission took 33.485 ms, with 6,042,232 live and 6,872,252 peak requested bytes. Generic construction took 241.465 ms and independent validation 163.306 ms, with 579,135,502 peak requested bytes. The instrumented artifact is 232,115 bytes; construction took 221.904 ms, admission 10.644 ms, validation 162.324 ms and construction peak was 574,794,105 requested bytes.

| Workload | Specialize ms | Validate ms | Admit ms | Construction peak bytes | Artifact bytes | Executable bytes | Proof bytes | Recovery anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 3923.666 | 2295.379 | 165.536 | 9647885982 | 13640322 | 2531671 | 11019238 | 24 |
| scalar_chain | 4076.280 | 2371.945 | 178.925 | 9885308482 | 18650666 | 2652625 | 15908612 | 24 |
| scalar_chain_large | 3938.987 | 2260.725 | 188.557 | 9677383909 | 30467253 | 2649407 | 27728417 | 24 |
| dynamic_loop | 3852.369 | 2267.852 | 167.271 | 9713172505 | 14215447 | 2549278 | 11576756 | 24 |
| structured | 3948.171 | 2315.949 | 166.298 | 9701151636 | 13887948 | 2545081 | 11253454 | 24 |
| repeated_calls | 3897.149 | 2265.429 | 171.129 | 9712581875 | 14209555 | 2549259 | 11570883 | 24 |
| higher_order | 3859.511 | 2245.548 | 166.347 | 9701698693 | 13886133 | 2537513 | 11259207 | 24 |
| handlers | 4244.538 | 2469.737 | 185.189 | 10119661918 | 20594404 | 2693155 | 17811820 | 24 |
| multi_shot | 3720.276 | 2220.288 | 163.157 | 5817889672 | 14463842 | 2480449 | 11893980 | 24 |
| long_cleanup | 3867.253 | 2281.756 | 168.199 | 9711099940 | 14707984 | 2563160 | 12055411 | 24 |
| retained_bytes | 3823.906 | 2251.533 | 167.594 | 9718564884 | 14463828 | 2551959 | 11822456 | 24 |

Preparation of reusable guest/runtime owners, measured separately in milliseconds:

| Workload | Prepare generic | Prepare specialized | Prepare instrumented |
| --- | --- | --- | --- |
| scalar | 0.049 | 0.003 | 0.003 |
| scalar_chain | 0.056 | 0.030 | 0.027 |
| scalar_chain_large | 0.135 | 0.096 | 0.095 |
| dynamic_loop | 0.040 | 0.012 | 0.008 |
| structured | 0.029 | 0.004 | 0.003 |
| repeated_calls | 0.038 | 0.011 | 0.008 |
| higher_order | 0.031 | 0.006 | 0.008 |
| handlers | 0.136 | 0.095 | 0.080 |
| multi_shot | 0.079 | 0.037 | 0.031 |
| long_cleanup | 0.052 | 0.021 | 0.014 |
| retained_bytes | 0.066 | 0.026 | 0.026 |

## Publication, restoration and switching

Median milliseconds; `G/S` means generic/specialized on the restricted base. Guest hydration and outer restore are different operations. Outer restore includes exact artifact admission and reconstruction checks. Switch observations use the in-memory publication owner and exclude network transport, durable SQLite publication and external authority work.

| Workload | Start G/S | Guest projection G/S | Guest restore G/S | Outer checkpoint G/S | Outer restore G/S | Switch G→S / S→G |
| --- | --- | --- | --- | --- | --- | --- |
| scalar | 0.153 / 0.502 | 0.664 / 0.668 | 0.056 / 0.366 | 1.284 / 3.507 | 1.927 / 4.606 | 6.406 / 6.060 |
| scalar_chain | 0.196 / 0.619 | 0.754 / 0.756 | 0.079 / 0.422 | 1.497 / 3.935 | 2.258 / 5.078 | 6.974 / 6.579 |
| scalar_chain_large | 0.300 / 0.774 | 1.847 / 1.869 | 0.153 / 0.468 | 1.953 / 4.719 | 3.048 / 6.253 | 8.455 / 8.071 |
| dynamic_loop | 0.242 / 0.671 | 0.726 / 0.719 | 0.066 / 0.434 | 1.376 / 3.692 | 2.056 / 4.731 | 6.668 / 6.428 |
| structured | 0.161 / 0.502 | 0.704 / 0.696 | 0.064 / 0.378 | 1.348 / 3.608 | 1.998 / 4.733 | 6.589 / 6.241 |
| repeated_calls | 0.242 / 0.688 | 4.931 / 5.360 | 0.121 / 0.502 | 4.870 / 11.270 | 8.688 / 15.679 | 8.421 / 7.967 |
| higher_order | 0.157 / 0.509 | 0.677 / 0.681 | 0.057 / 0.369 | 1.313 / 3.561 | 1.956 / 4.641 | 6.492 / 6.120 |
| handlers | 0.137 / 0.493 | 0.814 / 0.818 | 0.126 / 0.493 | 1.686 / 4.239 | 2.487 / 5.516 | 7.675 / 7.267 |
| multi_shot | 0.115 / 0.437 | 6.596 / 6.559 | 0.095 / 0.406 | 1.536 / 3.879 | 2.263 / 5.096 | 7.309 / 6.916 |
| long_cleanup | 0.183 / 0.614 | 53.377 / 53.319 | 1.370 / 1.724 | 10.380 / 21.334 | 15.353 / 26.584 | 45.242 / 44.770 |
| retained_bytes | 0.193 / 0.546 | 0.702 / 0.713 | 0.068 / 0.385 | 1.364 / 3.657 | 2.048 / 4.817 | 6.668 / 6.321 |

## Physical state and work

Values are maxima across the three inputs and nine repetitions on each base realization. `G/S` again means generic/specialized. Work counts are logical guest and physical base counts, not time. Effects count dispatched guest requests. Guest checkpoint length is identical across realizations for each matched cut.

| Workload | Guest work | Base work G/S | Effects | Live requested bytes G/S | Peak requested bytes G/S | Guest checkpoint bytes | Outer checkpoint bytes G/S |
| --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 3 | 3560 / 3383 | 0 | 54904 / 55503 | 214382 / 192323 | 79 | 1505 / 1192 |
| scalar_chain | 97 | 90032 / 88365 | 0 | 379808 / 405873 | 772970 / 815857 | 79 | 13285 / 7082 |
| scalar_chain_large | 385 | 357155 / 364817 | 0 | 1436236 / 1393376 | 1822588 / 1815963 | 84 | 73687 / 49478 |
| dynamic_loop | 341 | 335822 / 278438 | 0 | 108318 / 72154 | 383782 / 257975 | 93 | 3999 / 3044 |
| structured | 6 | 6957 / 6138 | 0 | 85501 / 56190 | 276435 / 219304 | 90 | 1944 / 1429 |
| repeated_calls | 389 | 555492 / 490913 | 0 | 723008 / 532814 | 2219198 / 2145218 | 1017 | 7125 / 6170 |
| higher_order | 5 | 5649 / 5279 | 0 | 86232 / 57154 | 279410 / 204836 | 79 | 2149 / 1514 |
| handlers | 110 | 167742 / 158932 | 0 | 383966 / 211729 | 1450854 / 1018583 | 79 | 13101 / 6990 |
| multi_shot | 23 | 57025 / 61064 | 3 | 180250 / 154960 | 268266 / 245950 | 178 | 4484 / 2711 |
| long_cleanup | 365 | 1764707 / 2773365 | 24 | 998082 / 1128081 | 5643246 / 5228404 | 981 | 8013 / 6510 |
| retained_bytes | 13 | 14059 / 13521 | 0 | 110015 / 95441 | 402837 / 331339 | 79 | 3529 / 2204 |

## Amortization and limits

The following estimate divides construction + independent validation + artifact admission + the specialized-minus-generic preparation cost by the mean generic-minus-specialized start-plus-execute time over the equally weighted three-input workload. A nonpositive saving has no measured finite break-even. The run count is the first integer strictly exceeding cost divided by saving. It assumes an available generic artifact, reusable prepared owners and stable timing; host variation and small timing differences can dominate the estimate.

| Workload | Initial incremental cost ms | Mean start + execute G ms | Mean start + execute S ms | Saving ms | Estimated new-session runs |
| --- | --- | --- | --- | --- | --- |
| scalar | 6384.535 | 1.099 | 1.466 | -0.367 | No measured break-even |
| scalar_chain | 6627.125 | 19.330 | 19.748 | -0.418 | No measured break-even |
| scalar_chain_large | 6388.231 | 81.290 | 85.392 | -4.102 | No measured break-even |
| dynamic_loop | 6287.463 | 48.108 | 43.208 | 4.900 | 1,284 |
| structured | 6430.393 | 1.892 | 2.094 | -0.201 | No measured break-even |
| repeated_calls | 6333.681 | 79.871 | 73.044 | 6.827 | 928 |
| higher_order | 6271.380 | 1.618 | 1.937 | -0.319 | No measured break-even |
| handlers | 6899.422 | 36.814 | 37.426 | -0.612 | No measured break-even |
| multi_shot | 6103.679 | 15.082 | 17.081 | -1.999 | No measured break-even |
| long_cleanup | 6317.177 | 221.459 | 411.209 | -189.750 | No measured break-even |
| retained_bytes | 6242.993 | 3.696 | 4.060 | -0.364 | No measured break-even |

These estimates exclude cache hits, storage, transfer, model-token cost and observation/publication costs, including outer restoration. Those costs can erase a saving. No timing result is an unconditional specialization policy.

The source builders preserve sharing at ordinary transitions; table tests measure 30/38/46 copied fields at 64/256/1024 entries and zero constructed blob bytes for a path update. These are concrete representation observations, not RSS measurements or universal complexity proofs. Instrumentation retains separate events and storage counters; disabled hooks are removed from the generic artifact.

Projection-cache counters unavailable in the immutable reference are emitted as `null`, not invented zeroes. Native process RSS, WASM timing, network transfer latency and live model token costs were not measured by this executable. Platform conformance and process mobility are separate qualification results. Deterministic model-action fixtures establish available choices, not autonomous model efficacy.

Raw output: 421 JSONL records, SHA-256 `ad53983e6ec2c63d4f9eff103809e6e6529258a513cd6a422c303726c2e22f42` (`kosmos-1df63be-economy.stdout`). The earlier baseline identifiers remain in this document's Git history.

## Retention query discovery

The ordinary retention query now returns when it first discovers the target.
Ordered breadth-first discovery fixes the same root and path as later dequeue;
roots are checked before any edge expansion, preserving zero-length priority.
The query still distinguishes complete absence from incomplete evidence and
preserves edge order, ownership labels and the view binding.

A captured Protean branch description contained 151 nodes, one root and 424
edges. Its requested target was the first edge from that root. The previous and
revised queries produced byte-identical 287-byte results on both the restricted
base and portable guest engine. Base transitions fell from 6,222 to 195; local
portable execution samples were 20.993 seconds and 0.464 seconds respectively.
These single samples ran during native qualification and establish no general
latency claim. These query observations predate the cost refresh above and retain their
recorded inputs; the query change affects separately authored view code.

The owning view tests cover later-root priority, duplicate roots and edges,
competing shortest paths, cycles and incomplete absence. They also check that
adding 423 edges after the decisive first edge adds no base transitions. The
full Protean process fixture separately qualifies integration and deadlines.
