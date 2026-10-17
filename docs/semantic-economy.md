# Semantic economy measurements

The tables below describe the earlier artifact named in this report. Its reference
used copied guest execution code with the then-current native storage. This revision
uses the immutable Kosmos `62279bce8e916e7fe613fe4575b3bc12e530596f` evaluator
and adds collection at public suspension; measurements for that candidate are pending.

Measured 2026-10-17 on Apple M2 Pro, macOS 27.2 (26B5112a), Zig 0.17.0, safe optimization. Runtime sources: Kosmos semantic source `81c7c457dc6fd8ccc75e3ed1fb0a8b77cfd8e98af792499dcfc4f4651ca671db`, Horos `a58967d541402b3661c05b4d599926114df75123`. The Kosmos source identity binds the authored implementation and compiler before this report is generated. This measurement ran separately from the native/platform qualification suites. These are local samples, not tail-latency or platform-independent claims.

Reproduce with `zig build bench-semantics -Doptimize=safe`. Select one workload with `-Deconomy-workload=scalar_chain`. Every measured realization is checked against the independent direct-native trace, canonical checkpoints and outcomes for the same inputs and controls. The direct-native and bootstrap evaluators are verification dependencies only.

Each family has three input samples. Generic, specialized and instrumented base execution each have three repetitions per input (nine observations); the direct native and bootstrap paths have one per input. Fixed handler and multi-shot programs vary their prescribed external responses where applicable. Dynamic loops use 16/32/48 iterations; cleanup uses 8/16/24 scopes; retained byte payloads use 1/8/64 KiB. Scalar inputs are 41/60/79; the chains contain 24 and 96 add/xor pairs on that dynamic input. The larger chain extends the original ten-workload suite; all original workloads and their inputs remain.

## Execution

Median milliseconds. This interval includes guest execution and its service events; explicit result observation, guest projection, restore and outer serialization are timed separately.

| Workload | Direct native | Generic bootstrap | Generic base | Specialized base | Instrumented base |
| --- | --- | --- | --- | --- | --- |
| scalar | 0.004 | 2.006 | 0.881 | 0.851 | 0.873 |
| scalar_chain | 0.015 | 90.577 | 20.937 | 20.573 | 20.757 |
| scalar_chain_large | 0.054 | 800.909 | 91.031 | 94.925 | 89.820 |
| dynamic_loop | 0.035 | 150.993 | 53.231 | 48.158 | 53.553 |
| structured | 0.005 | 4.251 | 1.631 | 1.505 | 1.658 |
| repeated_calls | 0.052 | 344.477 | 87.898 | 81.288 | 88.791 |
| higher_order | 0.005 | 3.732 | 1.375 | 1.363 | 1.420 |
| handlers | 0.048 | 203.865 | 41.258 | 41.828 | 41.497 |
| multi_shot | 0.038 | 36.826 | 14.798 | 16.715 | 15.110 |
| long_cleanup | 0.744 | 556.318 | 227.324 | 458.272 | 229.242 |
| retained_bytes | 0.018 | 13.961 | 3.757 | 3.631 | 3.481 |

Specialization removes repeated descriptor interpretation and scalar packing, as independently exercised by `semantic_specialization_tests.zig`. The specialized execution median was lower in these samples for `scalar`, `scalar_chain`, `dynamic_loop`, `structured`, `repeated_calls`, `higher_order`, `retained_bytes`. These timing differences describe these inputs and this execution profile; they do not establish universal speedup.

## Construction and artifacts

Construction and independent source/translation validation are separate. Peak bytes below are requested allocator bytes from construction, excluding allocator metadata and RSS. Construction, preparation, execution and restore have distinct allocation domains; their peaks must not be summed.

The generic artifact is 231,672 bytes, SHA-256 `2e5b5a1b7be183edfb1349904fb3df9a2c41f2d2740162ffafba20e5c3639750`, source identity `81c7c457dc6fd8ccc75e3ed1fb0a8b77cfd8e98af792499dcfc4f4651ca671db`. Admission took 45.547 ms, with 6,038,328 live and 6,868,348 peak requested bytes. Generic construction took 404.718 ms and independent validation 290.507 ms, with 525,117,046 peak requested bytes. The instrumented artifact is 231,949 bytes; construction took 380.073 ms, admission 16.358 ms, validation 296.497 ms and construction peak was 524,356,885 requested bytes.

| Workload | Specialize ms | Validate ms | Admit ms | Construction peak bytes | Artifact bytes | Executable bytes | Proof bytes | Recovery anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 9702.472 | 5972.723 | 459.445 | 9652485949 | 13664167 | 2530076 | 11044678 | 24 |
| scalar_chain | 10751.887 | 6607.869 | 534.723 | 9831379849 | 19274979 | 2651010 | 16534540 | 24 |
| scalar_chain_large | 9882.685 | 6118.329 | 508.665 | 9654823074 | 32928348 | 2647797 | 30191122 | 24 |
| dynamic_loop | 9897.433 | 6011.131 | 473.096 | 9717330340 | 14304594 | 2547665 | 11667516 | 24 |
| structured | 9623.978 | 5914.516 | 460.557 | 9661531791 | 13932555 | 2543465 | 11299677 | 24 |
| repeated_calls | 9609.770 | 5930.558 | 465.852 | 9716756655 | 14298775 | 2547646 | 11661716 | 24 |
| higher_order | 9380.595 | 5827.278 | 457.843 | 9663137945 | 13942901 | 2535917 | 11317571 | 24 |
| handlers | 11766.910 | 7268.939 | 576.500 | 10123413642 | 21208908 | 2691601 | 18427878 | 24 |
| multi_shot | 9256.627 | 5796.487 | 448.131 | 5612767247 | 14636633 | 2478833 | 12068387 | 24 |
| long_cleanup | 9753.871 | 6031.776 | 473.136 | 9732769948 | 14852938 | 2561543 | 12201982 | 24 |
| retained_bytes | 9546.390 | 5955.615 | 466.341 | 9676077714 | 14590818 | 2550346 | 11951059 | 24 |

Preparation of reusable guest/runtime owners, measured separately in milliseconds:

| Workload | Prepare generic | Prepare specialized | Prepare instrumented |
| --- | --- | --- | --- |
| scalar | 0.032 | 0.003 | 0.003 |
| scalar_chain | 0.057 | 0.028 | 0.030 |
| scalar_chain_large | 0.189 | 0.116 | 0.110 |
| dynamic_loop | 0.044 | 0.013 | 0.008 |
| structured | 0.028 | 0.004 | 0.003 |
| repeated_calls | 0.042 | 0.010 | 0.008 |
| higher_order | 0.041 | 0.006 | 0.007 |
| handlers | 0.140 | 0.109 | 0.089 |
| multi_shot | 0.089 | 0.037 | 0.032 |
| long_cleanup | 0.055 | 0.018 | 0.014 |
| retained_bytes | 0.072 | 0.022 | 0.025 |

## Publication, restoration and switching

Median milliseconds; `G/S` means generic/specialized on the restricted base. Guest hydration and outer restore are different operations. Outer restore includes exact artifact admission and reconstruction checks. Switch observations use the in-memory publication owner and exclude network transport, durable SQLite publication and external authority work.

| Workload | Start G/S | Guest projection G/S | Guest restore G/S | Outer checkpoint G/S | Outer restore G/S | Switch G→S / S→G |
| --- | --- | --- | --- | --- | --- | --- |
| scalar | 0.176 / 0.596 | 0.806 / 0.796 | 0.063 / 0.472 | 1.484 / 4.192 | 2.188 / 5.759 | 6.691 / 6.300 |
| scalar_chain | 0.211 / 0.675 | 0.866 / 0.903 | 0.088 / 0.516 | 1.616 / 4.509 | 2.474 / 5.834 | 7.873 / 7.190 |
| scalar_chain_large | 0.314 / 0.873 | 1.985 / 2.012 | 0.185 / 0.539 | 1.988 / 5.036 | 3.234 / 7.085 | 9.301 / 9.075 |
| dynamic_loop | 0.262 / 0.709 | 0.813 / 0.877 | 0.072 / 0.529 | 1.525 / 4.513 | 2.290 / 5.670 | 6.991 / 6.889 |
| structured | 0.172 / 0.590 | 0.826 / 0.821 | 0.067 / 0.444 | 1.546 / 4.107 | 2.366 / 5.698 | 7.065 / 6.736 |
| repeated_calls | 0.264 / 0.730 | 5.721 / 5.851 | 0.149 / 0.534 | 5.659 / 12.588 | 9.529 / 17.769 | 9.570 / 9.625 |
| higher_order | 0.171 / 0.611 | 0.895 / 0.910 | 0.062 / 0.455 | 1.715 / 4.374 | 2.588 / 6.046 | 6.877 / 6.517 |
| handlers | 0.160 / 0.557 | 2.718 / 2.666 | 0.154 / 0.581 | 5.679 / 11.969 | 8.150 / 15.275 | 8.692 / 8.334 |
| multi_shot | 0.122 / 0.489 | 9.744 / 9.979 | 0.097 / 0.491 | 1.643 / 4.276 | 2.308 / 5.470 | 7.866 / 7.209 |
| long_cleanup | 0.201 / 0.672 | 124.970 / 125.058 | 1.465 / 1.746 | 12.430 / 25.726 | 19.046 / 32.458 | 50.199 / 50.453 |
| retained_bytes | 0.195 / 0.685 | 1.400 / 1.457 | 0.076 / 0.435 | 2.782 / 6.524 | 4.152 / 8.416 | 6.990 / 6.715 |

## Physical state and work

Values are maxima across the three inputs and nine repetitions on each base realization. `G/S` again means generic/specialized. Work counts are logical guest and physical base counts, not time. Effects count dispatched guest requests. Guest checkpoint length is identical across realizations for each matched cut.

| Workload | Guest work | Base work G/S | Effects | Live requested bytes G/S | Peak requested bytes G/S | Guest checkpoint bytes | Outer checkpoint bytes G/S |
| --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 3 | 3005 / 2758 | 0 | 54472 / 46051 | 173480 / 157019 | 79 | 1582 / 1268 |
| scalar_chain | 97 | 89477 / 87740 | 0 | 380685 / 381263 | 773961 / 714523 | 79 | 13362 / 7158 |
| scalar_chain_large | 385 | 356592 / 364184 | 0 | 1436769 / 1393919 | 1822598 / 1815973 | 84 | 73697 / 49488 |
| dynamic_loop | 341 | 335259 / 277805 | 0 | 108855 / 72706 | 384319 / 257993 | 93 | 4017 / 3062 |
| structured | 6 | 6262 / 5391 | 0 | 75250 / 55699 | 218436 / 190939 | 90 | 2064 / 1549 |
| repeated_calls | 389 | 554919 / 489828 | 0 | 725143 / 534603 | 2219216 / 2127664 | 1017 | 7143 / 6188 |
| higher_order | 5 | 5084 / 4644 | 0 | 76388 / 58377 | 225982 / 203133 | 79 | 2285 / 1649 |
| handlers | 110 | 167187 / 158307 | 0 | 394971 / 222386 | 1463537 / 1030918 | 79 | 14222 / 8110 |
| multi_shot | 23 | 34013 / 38068 | 3 | 186821 / 135354 | 279068 / 232048 | 178 | 4486 / 2713 |
| long_cleanup | 365 | 650656 / 1662150 | 24 | 1038950 / 1167080 | 4865025 / 4830074 | 981 | 8477 / 6974 |
| retained_bytes | 13 | 13514 / 12906 | 0 | 311357 / 292714 | 1065153 / 892542 | 79 | 134993 / 133667 |

## Amortization and limits

The following estimate divides construction + independent validation + artifact admission + the specialized-minus-generic preparation cost by the mean generic-minus-specialized start-plus-execute time over the equally weighted three-input workload. A nonpositive saving has no measured finite break-even. The run count is the first integer strictly exceeding cost divided by saving. It assumes an available generic artifact, reusable prepared owners and stable timing; host variation and small timing differences can dominate the estimate.

| Workload | Initial incremental cost ms | Mean start + execute G ms | Mean start + execute S ms | Saving ms | Estimated new-session runs |
| --- | --- | --- | --- | --- | --- |
| scalar | 16134.612 | 1.188 | 1.442 | -0.254 | No measured break-even |
| scalar_chain | 17894.452 | 21.152 | 21.305 | -0.153 | No measured break-even |
| scalar_chain_large | 16509.607 | 90.983 | 95.471 | -4.488 | No measured break-even |
| dynamic_loop | 16381.628 | 53.121 | 47.981 | 5.139 | 3,188 |
| structured | 15999.027 | 1.873 | 2.183 | -0.310 | No measured break-even |
| repeated_calls | 16006.148 | 91.370 | 84.125 | 7.245 | 2,210 |
| higher_order | 15665.680 | 1.584 | 2.039 | -0.455 | No measured break-even |
| handlers | 19612.319 | 41.344 | 42.548 | -1.204 | No measured break-even |
| multi_shot | 15501.193 | 14.889 | 17.210 | -2.320 | No measured break-even |
| long_cleanup | 16258.746 | 249.800 | 480.501 | -230.701 | No measured break-even |
| retained_bytes | 15968.296 | 3.914 | 4.327 | -0.413 | No measured break-even |

These estimates exclude cache hits, storage, transfer, model-token cost and observation/publication costs, including outer restoration. Those costs can erase a saving. No timing result is an unconditional specialization policy.

The source builders preserve sharing at ordinary transitions; table tests measure 30/38/46 copied fields at 64/256/1024 entries and zero constructed blob bytes for a path update. These are concrete representation observations, not RSS measurements or universal complexity proofs. Instrumentation retains separate events and storage counters; disabled hooks are removed from the generic artifact.

Native process RSS, WASM timing, network transfer latency and live model token costs were not measured by this executable. Platform conformance and process mobility are separate qualification results. Deterministic model-action fixtures establish available choices, not autonomous model efficacy.

Raw output: 421 JSONL records, SHA-256 `a31470ce99ab2b4074d79e95ea7de5c8ffb76559a0f868cfe6be63cb43724923` (`kosmos-value-admission-economy.stdout`). The earlier baseline identifiers remain in this document's Git history.
