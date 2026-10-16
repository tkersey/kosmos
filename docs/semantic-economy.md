# Semantic economy measurements

Measured 2026-10-16 on Apple M2 Pro, macOS 27.2 (26B5112a), Zig 0.17.0, safe optimization. Runtime sources: Kosmos `bd35d9c1efce6a7f690cf9aa3a05bb2eb5796beb`, Horos `4b29dd0a2c9ccce6d5cd424542389bc8bcfcf9b1`. Other host work was active; these are local samples, not tail-latency or platform-independent claims.

Reproduce with `zig build bench-semantics -Doptimize=safe`. Select one workload with `-Deconomy-workload=scalar_chain`. Every measured realization is checked against the independent direct-native trace, canonical checkpoints and outcomes for the same inputs and controls. The direct-native and bootstrap evaluators are verification dependencies only.

Each family has three input samples. Generic, specialized and instrumented base execution each have three repetitions per input (nine observations); the direct native and bootstrap paths have one per input. Fixed handler and multi-shot programs vary their prescribed external responses where applicable. Dynamic loops use 16/32/48 iterations; cleanup uses 8/16/24 scopes; retained byte payloads use 1/8/64 KiB. Scalar inputs are 41/60/79; the chain contains 24 add/xor pairs on that dynamic input.

## Execution

Median milliseconds. This interval includes guest execution and its service events; explicit result observation, guest projection, restore and outer serialization are timed separately.

| Workload | Direct native | Generic bootstrap | Generic base | Specialized base | Instrumented base |
| --- | --- | --- | --- | --- | --- |
| scalar | 0.004 | 1.861 | 0.854 | 0.908 | 0.878 |
| scalar_chain | 0.019 | 84.332 | 19.346 | 18.757 | 19.449 |
| dynamic_loop | 0.026 | 147.339 | 49.334 | 50.331 | 49.362 |
| structured | 0.007 | 4.146 | 1.717 | 1.736 | 1.755 |
| repeated_calls | 0.056 | 324.793 | 84.969 | 85.259 | 85.373 |
| higher_order | 0.007 | 4.029 | 1.479 | 1.597 | 1.502 |
| handlers | 0.044 | 196.233 | 39.236 | 43.968 | 39.708 |
| multi_shot | 0.036 | 36.089 | 14.214 | 16.804 | 14.315 |
| long_cleanup | 0.426 | 507.691 | 207.957 | 416.695 | 209.157 |
| retained_bytes | 0.018 | 12.954 | 3.443 | 3.953 | 3.474 |

Specialization removes repeated descriptor interpretation and scalar packing, as independently exercised by `semantic_specialization_tests.zig`. The scalar chain shows a small local execution saving. The other nine workloads do not show an elapsed-time win. The direct native evaluator remains much faster in these samples.

The preceding observation at Kosmos `e647737` measured generic long-cleanup execution/projection at 606.166/529.813 ms. Ordered reconstruction and admitted-tail projection now measure 207.957/113.325 ms on the same workload. Separate frozen-binary workspace runs retained all 17 tests and measured total test execution at 433.119 seconds before these changes and 221.426 seconds after them. The archive-history case changed from 219.056 to 46.576 seconds. These single local comparisons exclude compilation and do not establish the CI wall-clock ceiling.

## Construction and artifacts

Construction and independent source/translation validation are separate. Peak bytes below are requested allocator bytes from construction, excluding allocator metadata and RSS. Construction, preparation, execution and restore have distinct allocation domains; their peaks must not be summed.

The generic artifact is 1,186,158 bytes, SHA-256 `e58be22ba27ad3586b906a4b73d0647fc5fafcb37c2fc859af3ebd327d389a48`, source identity `aa7a3b20f6dc0dd6d34efab9254109aeab4811249e83339984d373f0c0063571`. Admission took 17.594 ms, with 8,190,280 live and 9,376,438 peak requested bytes. Generic construction took 386.910 ms and independent validation 242.731 ms, with 907,768,400 peak requested bytes. The instrumented artifact is 1,188,213 bytes; construction took 396.891 ms, admission 16.631 ms, validation 243.121 ms and construction peak was 897,895,329 requested bytes.

| Workload | Specialize ms | Validate ms | Admit ms | Construction peak bytes | Artifact bytes | Executable bytes | Proof bytes | Recovery anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 10054.669 | 4404.455 | 435.805 | 9302320103 | 18363395 | 2543339 | 15723687 | 24 |
| scalar_chain | 11870.795 | 5163.083 | 545.579 | 9465206637 | 24461441 | 2713319 | 21651737 | 24 |
| dynamic_loop | 10378.033 | 4479.076 | 456.785 | 9358874935 | 19102823 | 2570508 | 16435946 | 24 |
| structured | 10980.423 | 4901.861 | 470.702 | 9345772366 | 18721894 | 2566111 | 16059414 | 24 |
| repeated_calls | 10782.260 | 4770.543 | 469.859 | 9358293805 | 19096667 | 2570490 | 16429808 | 24 |
| higher_order | 10755.368 | 4612.855 | 469.287 | 9325917409 | 18673729 | 2552231 | 16025129 | 24 |
| handlers | 14077.466 | 5915.651 | 618.442 | 9603713645 | 26940871 | 2817145 | 24027341 | 24 |
| multi_shot | 9997.245 | 4381.052 | 431.687 | 9296405042 | 19349564 | 2501262 | 16751933 | 24 |
| long_cleanup | 10451.915 | 4510.748 | 458.553 | 9406118438 | 19692674 | 2587353 | 17008952 | 24 |
| retained_bytes | 10030.753 | 4417.494 | 447.642 | 9362211343 | 19368151 | 2570043 | 16701739 | 24 |

## Publication, restoration and switching

Median milliseconds; `G/S` means generic/specialized on the restricted base. Guest hydration and outer restore are different operations. Outer restore includes exact artifact admission and reconstruction checks. Switch observations use the in-memory publication owner and exclude network transport, durable SQLite publication and external authority work.

| Workload | Start G/S | Guest projection G/S | Guest restore G/S | Outer checkpoint G/S | Outer restore G/S | Switch G→S / S→G |
| --- | --- | --- | --- | --- | --- | --- |
| scalar | 0.172 / 0.585 | 0.721 / 0.747 | 0.059 / 0.381 | 1.342 / 3.764 | 7.943 / 531.316 | 6.327 / 5.836 |
| scalar_chain | 0.212 / 0.722 | 0.786 / 0.824 | 0.081 / 0.468 | 1.498 / 4.060 | 8.200 / 690.406 | 6.685 / 6.234 |
| dynamic_loop | 0.259 / 0.778 | 0.761 / 0.754 | 0.070 / 0.461 | 1.411 / 3.775 | 8.142 / 570.826 | 6.450 / 5.811 |
| structured | 0.188 / 0.691 | 0.798 / 0.800 | 0.071 / 0.475 | 1.491 / 3.993 | 8.497 / 575.645 | 6.660 / 6.148 |
| repeated_calls | 0.277 / 0.815 | 5.267 / 6.301 | 0.139 / 0.587 | 4.810 / 12.101 | 14.898 / 605.945 | 8.637 / 8.086 |
| higher_order | 0.197 / 0.696 | 0.903 / 0.919 | 0.069 / 0.482 | 1.635 / 4.340 | 8.753 / 578.249 | 6.542 / 6.240 |
| handlers | 0.160 / 0.597 | 2.662 / 2.676 | 0.144 / 0.603 | 5.047 / 11.029 | 13.789 / 883.405 | 7.884 / 7.292 |
| multi_shot | 0.132 / 0.509 | 9.363 / 9.327 | 0.102 / 0.475 | 1.431 / 3.782 | 8.232 / 557.116 | 7.237 / 6.680 |
| long_cleanup | 0.196 / 0.681 | 113.325 / 113.620 | 1.378 / 1.745 | 11.559 / 23.772 | 23.223 / 606.450 | 46.451 / 46.271 |
| retained_bytes | 0.201 / 0.613 | 1.323 / 1.348 | 0.073 / 0.402 | 2.450 / 5.888 | 9.655 / 557.056 | 6.387 / 5.934 |

## Physical state and work

Values are maxima across the three inputs and nine repetitions on each base realization. `G/S` again means generic/specialized. Work counts are logical guest and physical base counts, not time. Effects count dispatched guest requests. Guest checkpoint length is identical across realizations for each matched cut.

| Workload | Guest work | Base work G/S | Effects | Live requested bytes G/S | Peak requested bytes G/S | Guest checkpoint bytes | Outer checkpoint bytes G/S |
| --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 3 | 3056 / 3059 | 0 | 54514 / 55679 | 175598 / 177027 | 79 | 1582 / 1268 |
| scalar_chain | 97 | 91503 / 86873 | 0 | 380563 / 380846 | 771763 / 703738 | 79 | 13362 / 7158 |
| dynamic_loop | 341 | 343279 / 327147 | 0 | 109079 / 77744 | 380581 / 273744 | 93 | 4015 / 3060 |
| structured | 6 | 6394 / 6098 | 0 | 74375 / 58287 | 219637 / 185223 | 90 | 2064 / 1549 |
| repeated_calls | 389 | 564438 / 548201 | 0 | 721196 / 524882 | 2210963 / 2007987 | 1017 | 7141 / 6186 |
| higher_order | 5 | 5191 / 5347 | 0 | 76361 / 61069 | 218689 / 198559 | 79 | 2285 / 1649 |
| handlers | 110 | 169716 / 178613 | 0 | 395451 / 227908 | 1423217 / 1059900 | 79 | 14222 / 8110 |
| multi_shot | 23 | 34497 / 41602 | 3 | 185984 / 135585 | 298505 / 248470 | 178 | 4487 / 2714 |
| long_cleanup | 365 | 657535 / 1709139 | 24 | 1037787 / 1160978 | 4990567 / 4785779 | 981 | 8502 / 6999 |
| retained_bytes | 13 | 13801 / 15120 | 0 | 311670 / 295632 | 1031590 / 878206 | 79 | 134993 / 133667 |

## Amortization and limits

The scalar-chain execution medians were 19.346 ms generic and 18.757 ms specialized. Medians of each measured start-plus-execute interval were 19.569 and 19.476 ms, a 0.093 ms saving. A simple construction + validation + admission / per-run-saving estimate is about 188,690 new-session runs. This assumes reusable prepared artifacts, the same workload and stable timing. It excludes compilation cache hits, storage, transfer, model-token cost and observation/publication costs; those can erase the saving. Repeated exact outer restoration does not break even in this workload. No finite elapsed-time break-even is supported for the other nine families.

The source builders preserve sharing at ordinary transitions; table tests measure 30/38/46 copied fields at 64/256/1024 entries and zero constructed blob bytes for a path update. These are concrete representation observations, not RSS measurements or universal complexity proofs. Instrumentation retains separate events and storage counters; disabled hooks are removed from the generic artifact.

Native process RSS, WASM timing, network transfer latency and live model token costs were not measured by this executable. Platform conformance and process mobility are separate qualification results. Deterministic model-action fixtures establish available choices, not autonomous model efficacy.

Raw output: 383 JSONL records, SHA-256 `5a2b7487cd7bf5961eac8d7d89aca4321d2cf121be9decf3f3e96711de7a8392` (`kosmos-fused-recovery-economy.stdout`). The earlier baseline identifiers remain in this document's Git history.
