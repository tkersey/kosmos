# Semantic economy measurements

Measured 2026-10-16 on Apple M2 Pro, macOS 27.2 (26B5112a), Zig 0.17.0, safe optimization. Runtime sources: Kosmos `e647737da65edc27e1e3acee72d8f3f65e771155`, Horos `fdbaa96872b669a0a1d78f9402ed87518611a1fc`. The `scalar_chain` row uses the additional benchmark fixture in this revision; it changes no runtime code. Other host work was active; these are local samples, not tail-latency or platform-independent claims.

Reproduce with `zig build bench-semantics -Doptimize=safe`. Select one workload with `-Deconomy-workload=scalar_chain`. Every measured realization is checked against the independent direct-native trace, canonical checkpoints and outcomes for the same inputs and controls. The direct-native and bootstrap evaluators are verification dependencies only.

Each family has three input samples. Generic, specialized and instrumented base execution each have three repetitions per input (nine observations); the direct native and bootstrap paths have one per input. Fixed handler and multi-shot programs vary their prescribed external responses where applicable. Dynamic loops use 16/32/48 iterations; cleanup uses 8/16/24 scopes; retained byte payloads use 1/8/64 KiB. Scalar inputs are 41/60/79; the chain contains 24 add/xor pairs on that dynamic input.

## Execution

Median milliseconds. This interval includes guest execution and its service events; explicit result observation, guest projection, restore and outer serialization are timed separately.

| Workload | Direct native | Generic bootstrap | Generic base | Specialized base | Instrumented base |
| --- | ---: | ---: | ---: | ---: | ---: |
| scalar | 0.004 | 1.989 | 0.896 | 0.957 | 0.896 |
| dynamic_loop | 0.026 | 153.248 | 50.165 | 50.866 | 49.727 |
| structured | 0.005 | 4.278 | 1.661 | 1.668 | 1.773 |
| repeated_calls | 0.052 | 354.222 | 84.110 | 85.916 | 85.014 |
| higher_order | 0.006 | 3.774 | 1.387 | 1.542 | 1.410 |
| handlers | 0.047 | 209.909 | 39.287 | 44.069 | 39.473 |
| multi_shot | 0.036 | 37.990 | 16.218 | 18.949 | 16.318 |
| long_cleanup | 0.512 | 617.478 | 606.166 | 832.866 | 608.895 |
| retained_bytes | 0.019 | 13.879 | 3.478 | 4.009 | 3.600 |
| scalar_chain | 0.016 | 86.763 | 19.722 | 19.097 | 19.901 |

Specialization removes repeated descriptor interpretation and scalar packing, as independently exercised by `semantic_specialization_tests.zig`. The nine initial workloads did not show an elapsed-time win. The added scalar chain isolates a longer run of dependent scalar operations and shows a small local execution saving; it does not establish a general speedup. The direct native evaluator remains much faster in these samples.

## Construction and artifacts

Construction and independent source/translation validation are separate. Peak bytes below are requested allocator bytes from construction, excluding allocator metadata and RSS. Construction, preparation, execution and restore have distinct allocation domains; their peaks must not be summed.

The generic artifact is 1,186,261 bytes. Its measured admission was 18.479 ms, with 8,454,156 live and 9,640,417 peak requested bytes. Generic source construction took 423.047 ms and independent validation 260.693 ms, with 895,972,755 peak requested bytes. The instrumented artifact is 1,188,316 bytes; construction was 417.467 ms, admission 17.273 ms, validation 263.343 ms and construction peak 896,477,960 requested bytes.

| Workload | Specialize ms | Validate ms | Admit ms | Construction peak bytes | Artifact bytes | Executable bytes | Proof bytes | Recovery anchors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| scalar | 10888.031 | 4693.700 | 464.161 | 9397935035 | 18467629 | 2558151 | 15812682 | 24 |
| dynamic_loop | 10985.384 | 4770.819 | 481.552 | 9394766338 | 19207226 | 2585306 | 16525124 | 24 |
| structured | 10901.993 | 4767.650 | 481.083 | 9381764902 | 18826288 | 2580923 | 16148569 | 24 |
| repeated_calls | 10807.540 | 4669.301 | 486.621 | 9393963744 | 19201196 | 2585287 | 16519113 | 24 |
| higher_order | 10398.248 | 4552.086 | 471.370 | 9406272713 | 18778215 | 2567041 | 16114378 | 24 |
| handlers | 13919.922 | 6053.324 | 628.440 | 9529887876 | 27044860 | 2831965 | 24116083 | 24 |
| multi_shot | 10262.301 | 4532.412 | 451.772 | 9380772272 | 19453644 | 2516062 | 16840786 | 24 |
| long_cleanup | 10892.461 | 4791.615 | 485.444 | 9416525734 | 19797142 | 2602168 | 17098178 | 24 |
| retained_bytes | 10820.071 | 4662.101 | 476.238 | 9397948359 | 19472755 | 2584859 | 16791100 | 24 |
| scalar_chain | 12485.929 | 5315.079 | 549.018 | 9867647514 | 24565454 | 2728152 | 21740490 | 24 |

## Publication, restoration and switching

Median milliseconds; `G/S` means generic/specialized on the restricted base. Guest hydration and outer restore are different operations. Outer restore includes exact artifact admission and reconstruction checks. Switch observations use the in-memory publication owner and exclude network transport, durable SQLite publication and external authority work.

| Workload | Start G/S | Guest projection G/S | Guest restore G/S | Outer checkpoint G/S | Outer restore G/S | Switch G→S / S→G |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| scalar | 0.187 / 0.661 | 0.852 / 0.887 | 0.065 / 0.451 | 1.604 / 4.339 | 8.478 / 584.577 | 7.009 / 6.580 |
| dynamic_loop | 0.261 / 0.792 | 0.872 / 0.874 | 0.070 / 0.500 | 1.613 / 4.240 | 8.633 / 603.221 | 6.928 / 6.391 |
| structured | 0.185 / 0.639 | 0.888 / 0.888 | 0.070 / 0.443 | 1.675 / 4.295 | 8.496 / 596.141 | 7.231 / 6.545 |
| repeated_calls | 0.271 / 0.794 | 12.740 / 12.938 | 0.134 / 0.550 | 11.702 / 24.659 | 28.866 / 640.098 | 9.879 / 9.161 |
| higher_order | 0.179 / 0.640 | 1.028 / 1.071 | 0.062 / 0.432 | 1.913 / 4.944 | 8.931 / 587.191 | 6.841 / 6.408 |
| handlers | 0.157 / 0.624 | 5.726 / 5.583 | 0.147 / 0.646 | 10.831 / 22.116 | 22.381 / 927.751 | 8.546 / 7.980 |
| multi_shot | 0.124 / 0.509 | 14.424 / 14.572 | 0.098 / 0.468 | 1.607 / 4.171 | 8.480 / 586.805 | 7.977 / 7.440 |
| long_cleanup | 0.208 / 0.703 | 529.813 / 530.988 | 1.441 / 1.945 | 59.409 / 119.589 | 95.944 / 771.360 | 202.778 / 198.577 |
| retained_bytes | 0.221 / 0.692 | 1.866 / 1.939 | 0.075 / 0.464 | 3.469 / 8.037 | 11.528 / 598.244 | 7.124 / 6.560 |
| scalar_chain | 0.218 / 0.734 | 0.870 / 0.893 | 0.085 / 0.502 | 1.640 / 4.392 | 8.475 / 735.503 | 7.344 / 6.779 |

## Physical state and work

Values are maxima across the three inputs and nine repetitions on each base realization. `G/S` again means generic/specialized. Work counts are logical guest and physical base counts, not time. Effects count dispatched guest requests. Guest checkpoint length is identical across realizations for each matched cut.

| Workload | Guest work | Base work G/S | Effects | Live requested bytes G/S | Peak requested bytes G/S | Guest checkpoint bytes | Outer checkpoint bytes G/S |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| scalar | 3 | 3056 / 3059 | 0 | 54514 / 55607 | 175598 / 176955 | 79 | 1582 / 1268 |
| dynamic_loop | 341 | 343279 / 327147 | 0 | 109079 / 77672 | 380581 / 273672 | 93 | 4015 / 3060 |
| structured | 6 | 6394 / 6098 | 0 | 74375 / 58287 | 219637 / 185223 | 90 | 2064 / 1549 |
| repeated_calls | 389 | 564438 / 548201 | 0 | 721196 / 524810 | 2210963 / 2007915 | 1017 | 7141 / 6186 |
| higher_order | 5 | 5191 / 5347 | 0 | 76361 / 60997 | 218689 / 198487 | 79 | 2285 / 1649 |
| handlers | 110 | 169716 / 178613 | 0 | 395451 / 227908 | 1423217 / 1059900 | 79 | 14222 / 8110 |
| multi_shot | 23 | 34497 / 41602 | 3 | 185984 / 135585 | 281891 / 231856 | 178 | 4487 / 2714 |
| long_cleanup | 365 | 657535 / 1709139 | 24 | 1037787 / 1160906 | 4990567 / 4785707 | 981 | 8502 / 6999 |
| retained_bytes | 13 | 13801 / 15120 | 0 | 311670 / 295668 | 1031590 / 872915 | 79 | 134993 / 133667 |
| scalar_chain | 97 | 91503 / 86873 | 0 | 380563 / 380774 | 771763 / 703666 | 79 | 13362 / 7158 |

## Amortization and limits

The scalar-chain execution medians were 19.722 ms generic and 19.097 ms specialized (0.625 ms saved). Including creation of a new session reduces the median saving to 0.159 ms. A simple construction + validation + admission / per-run-saving estimate is about 115532 new-session runs. This assumes reusable prepared artifacts, the same workload and stable timing. It excludes compilation cache hits, storage, transfer, model-token cost and observation/publication costs; those can erase the saving. Repeated exact outer restoration does not break even in this workload. No finite elapsed-time break-even is supported for the nine initial families.

The source builders preserve sharing at ordinary transitions; table tests measure 30/38/46 copied fields at 64/256/1024 entries and zero constructed blob bytes for a path update. These are concrete representation observations, not RSS measurements or universal complexity proofs. Instrumentation retains separate events and storage counters; disabled hooks are removed from the generic artifact.

Native process RSS, WASM timing, network transfer latency and live model token costs were not measured by this executable. Platform conformance and process mobility are separate qualification results. Deterministic model-action fixtures establish available choices, not autonomous model efficacy.

Raw-output SHA-256 identifiers for this observation:

- `8ffe22ffceea92467aafd50465bb9b48d5df05d81ea180bd373e629e6caae8cd` (345 JSONL records, kosmos-economy-final-candidate.jsonl).
- `cbda222b85459ca847487cc37a61b01dc0e20a99fcddd5d1f0579fe62901b860` (41 JSONL records, kosmos-economy-scalar-chain.jsonl).
