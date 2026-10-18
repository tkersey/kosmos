# Semantic economy measurements

Measured 2026-10-17 on Apple M2 Pro, macOS 27.2 (26B5112a), Zig 0.17.0, safe optimization. Runtime sources: Kosmos host facade `200e06c42d9d9975f3736c18bc2e953686271191`, semantic source `1897ed209557817c475bd14d10614024ea5f327823aec7a143d0e0337eb3bbfc`, Horos `592eb0839326f2d8a423b59ce2746ab18ef5136a`. The Kosmos source identity binds the authored implementation and compiler before this report is generated. This measurement used a separate benchmark invocation; other review work was active on the host. These are local samples, not tail-latency or platform-independent claims.

Reproduce with `zig build bench-semantics -Doptimize=safe`. Select one workload with `-Deconomy-workload=scalar_chain`. Every measured realization is checked against the independent direct-native trace, canonical checkpoints and outcomes for the same inputs and controls. The direct-native and bootstrap evaluators are verification dependencies only, fetched from immutable Kosmos `62279bce8e916e7fe613fe4575b3bc12e530596f` with package identity `kosmos-8.0.0-vcJNB7_PDwCsxCmIN8VIVZsi9fW8qHX7Y5xesXeS6Kn5`. They retain that historical implementation and storage; no copied current engine supplies the reference. The reference shares the selected Horos admission dependency, so this comparison is independent execution evidence, not independent admission evidence.

Each family has three input samples. Generic, specialized and instrumented base execution each have three repetitions per input (nine observations); the direct native and bootstrap paths have one per input. Fixed handler and multi-shot programs vary their prescribed external responses where applicable. Dynamic loops use 16/32/48 iterations; cleanup uses 8/16/24 scopes; retained byte payloads use 1/8/64 KiB. Scalar inputs are 41/60/79; the chains contain 24 and 96 add/xor pairs on that dynamic input. The larger chain extends the original ten-workload suite; all original workloads and their inputs remain.

## Execution

Median milliseconds. This interval includes guest execution and its service events; explicit result observation, guest projection, restore and outer serialization are timed separately.

| Workload | Direct native | Generic bootstrap | Generic base | Specialized base | Instrumented base |
| --- | --- | --- | --- | --- | --- |
| scalar | 0.004 | 2.349 | 1.005 | 1.018 | 1.001 |
| scalar_chain | 0.017 | 88.638 | 20.355 | 20.489 | 20.360 |
| scalar_chain_large | 0.059 | 772.254 | 85.806 | 90.050 | 87.074 |
| dynamic_loop | 0.033 | 150.976 | 49.205 | 44.159 | 49.055 |
| structured | 0.009 | 4.633 | 1.816 | 1.711 | 1.834 |
| repeated_calls | 0.054 | 356.821 | 82.142 | 76.269 | 82.426 |
| higher_order | 0.007 | 4.320 | 1.547 | 1.518 | 1.550 |
| handlers | 0.048 | 201.383 | 37.144 | 37.628 | 37.121 |
| multi_shot | 0.041 | 58.689 | 15.298 | 17.093 | 15.421 |
| long_cleanup | 0.435 | 1167.723 | 202.676 | 393.457 | 206.532 |
| retained_bytes | 0.018 | 14.070 | 3.580 | 3.679 | 3.590 |

Specialization removes repeated descriptor interpretation and scalar packing, as independently exercised by `semantic_specialization_tests.zig`. The specialized execution median was lower in these samples for `dynamic_loop`, `structured`, `repeated_calls`, `higher_order`. These timing differences describe these inputs and this execution profile; they do not establish universal speedup.

## Construction and artifacts

Construction and independent source/translation validation are separate. Peak bytes below are requested allocator bytes from construction, excluding allocator metadata and RSS. Construction, preparation, execution and restore have distinct allocation domains; their peaks must not be summed.

The generic artifact is 231,839 bytes, SHA-256 `a56f43b35c83e8271aa8bd09dd293d27f45ad9e1c72a4081a574c7dd6de0512a`, source identity `1897ed209557817c475bd14d10614024ea5f327823aec7a143d0e0337eb3bbfc`. Admission took 12.189 ms, with 6,042,188 live and 6,872,208 peak requested bytes. Generic construction took 243.995 ms and independent validation 177.400 ms, with 578,892,563 peak requested bytes. The instrumented artifact is 232,116 bytes; construction took 241.822 ms, admission 11.343 ms, validation 176.945 ms and construction peak was 574,541,722 requested bytes.

| Workload | Specialize ms | Validate ms | Admit ms | Construction peak bytes | Artifact bytes | Executable bytes | Proof bytes | Recovery anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 4120.652 | 2368.273 | 167.554 | 9648018820 | 13640310 | 2531684 | 11019213 | 24 |
| scalar_chain | 4203.119 | 2450.874 | 182.999 | 9885442820 | 18650654 | 2652638 | 15908587 | 24 |
| scalar_chain_large | 4134.132 | 2354.506 | 190.554 | 9677524157 | 30467241 | 2649420 | 27728392 | 24 |
| dynamic_loop | 4133.768 | 2383.932 | 169.860 | 9713332977 | 14215435 | 2549291 | 11576731 | 24 |
| structured | 4257.516 | 2468.013 | 177.921 | 9701304520 | 13887936 | 2545094 | 11253429 | 24 |
| repeated_calls | 4171.780 | 2351.267 | 172.933 | 9712740769 | 14209543 | 2549272 | 11570858 | 24 |
| higher_order | 3935.077 | 2356.465 | 167.535 | 9701849801 | 13886121 | 2537526 | 11259182 | 24 |
| handlers | 4486.235 | 2561.657 | 189.612 | 10119802416 | 20594392 | 2693168 | 17811795 | 24 |
| multi_shot | 3892.763 | 2310.272 | 170.288 | 5820833468 | 14463830 | 2480462 | 11893955 | 24 |
| long_cleanup | 4029.561 | 2378.394 | 172.791 | 9711250586 | 14707972 | 2563173 | 12055386 | 24 |
| retained_bytes | 4008.683 | 2363.963 | 173.544 | 9718728510 | 14463816 | 2551972 | 11822431 | 24 |

Preparation of reusable guest/runtime owners, measured separately in milliseconds:

| Workload | Prepare generic | Prepare specialized | Prepare instrumented |
| --- | --- | --- | --- |
| scalar | 0.061 | 0.004 | 0.003 |
| scalar_chain | 0.057 | 0.035 | 0.033 |
| scalar_chain_large | 0.137 | 0.102 | 0.096 |
| dynamic_loop | 0.039 | 0.017 | 0.009 |
| structured | 0.029 | 0.004 | 0.004 |
| repeated_calls | 0.036 | 0.011 | 0.009 |
| higher_order | 0.033 | 0.006 | 0.008 |
| handlers | 0.141 | 0.097 | 0.083 |
| multi_shot | 0.085 | 0.048 | 0.034 |
| long_cleanup | 0.055 | 0.019 | 0.015 |
| retained_bytes | 0.092 | 0.028 | 0.030 |

## Publication, restoration and switching

Median milliseconds; `G/S` means generic/specialized on the restricted base. Guest hydration and outer restore are different operations. Outer restore includes exact artifact admission and reconstruction checks. Switch observations use the in-memory publication owner and exclude network transport, durable SQLite publication and external authority work.

| Workload | Start G/S | Guest projection G/S | Guest restore G/S | Outer checkpoint G/S | Outer restore G/S | Switch G→S / S→G |
| --- | --- | --- | --- | --- | --- | --- |
| scalar | 0.163 / 0.538 | 0.699 / 0.702 | 0.058 / 0.402 | 1.365 / 3.628 | 2.017 / 4.833 | 6.790 / 6.411 |
| scalar_chain | 0.217 / 0.718 | 0.804 / 0.805 | 0.090 / 0.534 | 1.580 / 4.235 | 2.342 / 5.643 | 7.527 / 6.985 |
| scalar_chain_large | 0.332 / 0.820 | 1.986 / 1.986 | 0.168 / 0.510 | 2.062 / 4.879 | 3.312 / 6.741 | 9.244 / 8.878 |
| dynamic_loop | 0.262 / 0.703 | 0.744 / 0.746 | 0.069 / 0.450 | 1.408 / 3.744 | 2.115 / 4.956 | 7.241 / 6.640 |
| structured | 0.177 / 0.546 | 0.743 / 0.736 | 0.067 / 0.429 | 1.393 / 3.768 | 2.087 / 4.953 | 6.832 / 6.490 |
| repeated_calls | 0.256 / 0.760 | 5.232 / 5.686 | 0.130 / 0.566 | 5.111 / 11.570 | 9.261 / 16.624 | 9.037 / 8.792 |
| higher_order | 0.174 / 0.554 | 0.720 / 0.718 | 0.061 / 0.410 | 1.371 / 3.732 | 2.051 / 4.885 | 6.852 / 6.519 |
| handlers | 0.139 / 0.509 | 0.828 / 0.834 | 0.128 / 0.533 | 1.721 / 4.295 | 2.511 / 5.748 | 7.992 / 7.598 |
| multi_shot | 0.121 / 0.457 | 6.723 / 6.699 | 0.099 / 0.434 | 1.577 / 4.032 | 2.321 / 5.319 | 7.532 / 7.122 |
| long_cleanup | 0.177 / 0.617 | 53.846 / 53.855 | 1.393 / 1.742 | 10.449 / 21.550 | 15.572 / 27.087 | 45.672 / 45.165 |
| retained_bytes | 0.200 / 0.576 | 0.733 / 0.737 | 0.070 / 0.402 | 1.423 / 3.763 | 2.116 / 4.990 | 6.970 / 6.638 |

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
| scalar | 6656.422 | 1.167 | 1.567 | -0.400 | No measured break-even |
| scalar_chain | 6836.971 | 20.673 | 21.209 | -0.536 | No measured break-even |
| scalar_chain_large | 6679.158 | 86.252 | 91.087 | -4.835 | No measured break-even |
| dynamic_loop | 6687.537 | 49.618 | 44.692 | 4.926 | 1,358 |
| structured | 6903.426 | 2.002 | 2.260 | -0.258 | No measured break-even |
| repeated_calls | 6695.954 | 85.721 | 79.145 | 6.577 | 1,019 |
| higher_order | 6459.050 | 1.749 | 2.077 | -0.328 | No measured break-even |
| handlers | 7237.459 | 37.367 | 38.442 | -1.075 | No measured break-even |
| multi_shot | 6373.286 | 15.461 | 17.627 | -2.166 | No measured break-even |
| long_cleanup | 6580.710 | 225.525 | 416.841 | -191.315 | No measured break-even |
| retained_bytes | 6546.125 | 3.805 | 4.307 | -0.502 | No measured break-even |

These estimates exclude cache hits, storage, transfer, model-token cost and observation/publication costs, including outer restoration. Those costs can erase a saving. No timing result is an unconditional specialization policy.

The source builders preserve sharing at ordinary transitions; table tests measure 30/38/46 copied fields at 64/256/1024 entries and zero constructed blob bytes for a path update. These are concrete representation observations, not RSS measurements or universal complexity proofs. Instrumentation retains separate events and storage counters; disabled hooks are removed from the generic artifact.

Projection-cache counters unavailable in the immutable reference are emitted as `null`, not invented zeroes. Native process RSS, WASM timing, network transfer latency and live model token costs were not measured by this executable. Platform conformance and process mobility are separate qualification results. Deterministic model-action fixtures establish available choices, not autonomous model efficacy.

Raw output: 421 JSONL records, SHA-256 `4c618d9c115dd231b3cd5de6e4f92c89ab4eb9bfeb31edadcd7acd7bd6208337` (`kosmos-200e06c-economy.stdout`). The earlier baseline identifiers remain in this document's Git history.

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
