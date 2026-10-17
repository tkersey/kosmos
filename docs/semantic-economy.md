# Semantic economy measurements

Measured 2026-10-17 on Apple M2 Pro, macOS 27.2 (26B5112a), Zig 0.17.0, safe optimization. Runtime sources: Kosmos host facade `731a4ed1fce8d22e036a251c421f64ececbb9b21`, semantic source `1897ed209557817c475bd14d10614024ea5f327823aec7a143d0e0337eb3bbfc`, Horos `a58967d541402b3661c05b4d599926114df75123`. The Kosmos source identity binds the authored implementation and compiler before this report is generated. This measurement ran separately from the native/platform qualification suites. These are local samples, not tail-latency or platform-independent claims.

Reproduce with `zig build bench-semantics -Doptimize=safe`. Select one workload with `-Deconomy-workload=scalar_chain`. Every measured realization is checked against the independent direct-native trace, canonical checkpoints and outcomes for the same inputs and controls. The direct-native and bootstrap evaluators are verification dependencies only, fetched from immutable Kosmos `62279bce8e916e7fe613fe4575b3bc12e530596f` with package identity `kosmos-8.0.0-vcJNB7_PDwCsxCmIN8VIVZsi9fW8qHX7Y5xesXeS6Kn5`. They retain that historical implementation and storage; no copied current engine supplies the reference. The reference shares the selected Horos admission dependency, so this comparison is independent execution evidence, not independent admission evidence.

Each family has three input samples. Generic, specialized and instrumented base execution each have three repetitions per input (nine observations); the direct native and bootstrap paths have one per input. Fixed handler and multi-shot programs vary their prescribed external responses where applicable. Dynamic loops use 16/32/48 iterations; cleanup uses 8/16/24 scopes; retained byte payloads use 1/8/64 KiB. Scalar inputs are 41/60/79; the chains contain 24 and 96 add/xor pairs on that dynamic input. The larger chain extends the original ten-workload suite; all original workloads and their inputs remain.

## Execution

Median milliseconds. This interval includes guest execution and its service events; explicit result observation, guest projection, restore and outer serialization are timed separately.

| Workload | Direct native | Generic bootstrap | Generic base | Specialized base | Instrumented base |
| --- | --- | --- | --- | --- | --- |
| scalar | 0.004 | 2.348 | 0.980 | 1.006 | 0.983 |
| scalar_chain | 0.017 | 85.626 | 19.338 | 19.286 | 19.340 |
| scalar_chain_large | 0.056 | 736.811 | 81.680 | 85.934 | 82.664 |
| dynamic_loop | 0.031 | 146.059 | 47.934 | 43.891 | 49.113 |
| structured | 0.005 | 4.579 | 1.780 | 1.655 | 1.777 |
| repeated_calls | 0.051 | 344.150 | 78.500 | 72.780 | 79.289 |
| higher_order | 0.007 | 4.252 | 1.507 | 1.479 | 1.502 |
| handlers | 0.045 | 200.886 | 37.252 | 37.549 | 37.153 |
| multi_shot | 0.041 | 58.593 | 18.495 | 20.338 | 18.569 |
| long_cleanup | 0.432 | 1179.442 | 257.470 | 447.648 | 258.379 |
| retained_bytes | 0.019 | 14.074 | 3.569 | 3.640 | 3.554 |

Specialization removes repeated descriptor interpretation and scalar packing, as independently exercised by `semantic_specialization_tests.zig`. The specialized execution median was lower in these samples for `scalar_chain`, `dynamic_loop`, `structured`, `repeated_calls`, `higher_order`. These timing differences describe these inputs and this execution profile; they do not establish universal speedup.

## Construction and artifacts

Construction and independent source/translation validation are separate. Peak bytes below are requested allocator bytes from construction, excluding allocator metadata and RSS. Construction, preparation, execution and restore have distinct allocation domains; their peaks must not be summed.

The generic artifact is 231,839 bytes, SHA-256 `cb4af30f5c58aee7159f56aa4a08a5fb41a6748061260066edc24f7dadf74714`, source identity `1897ed209557817c475bd14d10614024ea5f327823aec7a143d0e0337eb3bbfc`. Admission took 45.290 ms, with 6,042,188 live and 6,872,208 peak requested bytes. Generic construction took 362.128 ms and independent validation 261.995 ms, with 579,026,591 peak requested bytes. The instrumented artifact is 232,116 bytes; construction took 345.420 ms, admission 15.716 ms, validation 264.536 ms and construction peak was 574,674,940 requested bytes.

| Workload | Specialize ms | Validate ms | Admit ms | Construction peak bytes | Artifact bytes | Executable bytes | Proof bytes | Recovery anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 8781.024 | 5491.061 | 426.792 | 9648018820 | 13640310 | 2531684 | 11019213 | 24 |
| scalar_chain | 9839.441 | 6160.373 | 495.416 | 9885442820 | 18650654 | 2652638 | 15908587 | 24 |
| scalar_chain_large | 9058.595 | 5561.591 | 470.539 | 9677524157 | 30467241 | 2649420 | 27728392 | 24 |
| dynamic_loop | 8947.110 | 5558.826 | 436.755 | 9713332977 | 14215435 | 2549291 | 11576731 | 24 |
| structured | 8917.386 | 5563.800 | 433.268 | 9701304520 | 13887936 | 2545094 | 11253429 | 24 |
| repeated_calls | 8948.174 | 5548.786 | 438.722 | 9712740769 | 14209543 | 2549272 | 11570858 | 24 |
| higher_order | 8742.553 | 5458.656 | 430.771 | 9701849801 | 13886121 | 2537526 | 11259182 | 24 |
| handlers | 10915.256 | 6785.242 | 543.190 | 10119802416 | 20594392 | 2693168 | 17811795 | 24 |
| multi_shot | 8551.228 | 5374.851 | 421.694 | 5820833468 | 14463830 | 2480462 | 11893955 | 24 |
| long_cleanup | 9041.719 | 5646.999 | 444.945 | 9711250586 | 14707972 | 2563173 | 12055386 | 24 |
| retained_bytes | 8880.233 | 5552.453 | 438.039 | 9718728510 | 14463816 | 2551972 | 11822431 | 24 |

Preparation of reusable guest/runtime owners, measured separately in milliseconds:

| Workload | Prepare generic | Prepare specialized | Prepare instrumented |
| --- | --- | --- | --- |
| scalar | 0.051 | 0.003 | 0.003 |
| scalar_chain | 0.061 | 0.028 | 0.028 |
| scalar_chain_large | 0.135 | 0.110 | 0.097 |
| dynamic_loop | 0.036 | 0.010 | 0.009 |
| structured | 0.032 | 0.004 | 0.003 |
| repeated_calls | 0.041 | 0.012 | 0.009 |
| higher_order | 0.034 | 0.006 | 0.009 |
| handlers | 0.130 | 0.097 | 0.085 |
| multi_shot | 0.085 | 0.038 | 0.033 |
| long_cleanup | 0.058 | 0.019 | 0.014 |
| retained_bytes | 0.071 | 0.023 | 0.030 |

## Publication, restoration and switching

Median milliseconds; `G/S` means generic/specialized on the restricted base. Guest hydration and outer restore are different operations. Outer restore includes exact artifact admission and reconstruction checks. Switch observations use the in-memory publication owner and exclude network transport, durable SQLite publication and external authority work.

| Workload | Start G/S | Guest projection G/S | Guest restore G/S | Outer checkpoint G/S | Outer restore G/S | Switch G→S / S→G |
| --- | --- | --- | --- | --- | --- | --- |
| scalar | 0.161 / 0.531 | 0.654 / 0.657 | 0.059 / 0.391 | 1.247 / 3.458 | 1.872 / 4.475 | 6.343 / 5.947 |
| scalar_chain | 0.200 / 0.641 | 0.727 / 0.728 | 0.085 / 0.448 | 1.432 / 3.821 | 2.165 / 5.120 | 6.940 / 6.525 |
| scalar_chain_large | 0.313 / 0.786 | 1.806 / 1.830 | 0.159 / 0.479 | 1.885 / 4.584 | 2.986 / 6.281 | 8.451 / 8.106 |
| dynamic_loop | 0.245 / 0.696 | 0.698 / 0.700 | 0.072 / 0.456 | 1.311 / 3.808 | 1.972 / 4.860 | 6.607 / 6.036 |
| structured | 0.169 / 0.540 | 0.685 / 0.684 | 0.066 / 0.401 | 1.299 / 3.554 | 1.931 / 4.586 | 6.481 / 6.122 |
| repeated_calls | 0.254 / 0.697 | 4.911 / 5.395 | 0.124 / 0.513 | 4.748 / 11.066 | 8.694 / 16.514 | 8.456 / 7.995 |
| higher_order | 0.165 / 0.538 | 0.665 / 0.671 | 0.060 / 0.386 | 1.263 / 3.493 | 1.899 / 4.523 | 6.365 / 6.017 |
| handlers | 0.143 / 0.507 | 0.795 / 0.785 | 0.132 / 0.513 | 1.632 / 4.105 | 2.381 / 5.411 | 7.599 / 7.176 |
| multi_shot | 0.120 / 0.458 | 6.489 / 6.484 | 0.100 / 0.431 | 1.482 / 3.848 | 2.217 / 4.996 | 7.253 / 6.766 |
| long_cleanup | 0.182 / 0.620 | 53.360 / 53.222 | 1.366 / 1.720 | 10.268 / 21.073 | 15.394 / 26.487 | 45.047 / 44.807 |
| retained_bytes | 0.208 / 0.585 | 0.689 / 0.693 | 0.071 / 0.404 | 1.328 / 3.583 | 1.974 / 4.656 | 6.598 / 6.040 |

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
| scalar | 14698.830 | 1.151 | 1.559 | -0.408 | No measured break-even |
| scalar_chain | 16495.196 | 19.543 | 19.925 | -0.382 | No measured break-even |
| scalar_chain_large | 15090.701 | 81.915 | 86.713 | -4.798 | No measured break-even |
| dynamic_loop | 14942.665 | 48.811 | 44.200 | 4.611 | 3,242 |
| structured | 14914.426 | 1.958 | 2.201 | -0.243 | No measured break-even |
| repeated_calls | 14935.654 | 81.067 | 74.529 | 6.538 | 2,285 |
| higher_order | 14631.952 | 1.680 | 2.031 | -0.352 | No measured break-even |
| handlers | 18243.656 | 37.479 | 38.100 | -0.621 | No measured break-even |
| multi_shot | 14347.725 | 18.734 | 20.864 | -2.130 | No measured break-even |
| long_cleanup | 15133.624 | 288.804 | 480.648 | -191.845 | No measured break-even |
| retained_bytes | 14870.677 | 3.793 | 4.251 | -0.457 | No measured break-even |

These estimates exclude cache hits, storage, transfer, model-token cost and observation/publication costs, including outer restoration. Those costs can erase a saving. No timing result is an unconditional specialization policy.

The source builders preserve sharing at ordinary transitions; table tests measure 30/38/46 copied fields at 64/256/1024 entries and zero constructed blob bytes for a path update. These are concrete representation observations, not RSS measurements or universal complexity proofs. Instrumentation retains separate events and storage counters; disabled hooks are removed from the generic artifact.

Projection-cache counters unavailable in the immutable reference are emitted as `null`, not invented zeroes. Native process RSS, WASM timing, network transfer latency and live model token costs were not measured by this executable. Platform conformance and process mobility are separate qualification results. Deterministic model-action fixtures establish available choices, not autonomous model efficacy.

Raw output: 421 JSONL records, SHA-256 `bc1175ec16be60e26927dd9112d23386d225fc5c856588331c284622ebdc71a5` (`kosmos-731a4ed-economy.stdout`). The earlier baseline identifiers remain in this document's Git history.

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
latency claim. The semantic artifact and the eleven workload measurements above
are unchanged; this change is to the separately authored view query.

The owning view tests cover later-root priority, duplicate roots and edges,
competing shortest paths, cycles and incomplete absence. They also check that
adding 423 edges after the decisive first edge adds no base transitions. The
full Protean process fixture separately qualifies integration and deadlines.
