# Semantic economy measurements

Measured 2026-10-17 on Apple M2 Pro, macOS 27.2 (26B5112a), Zig 0.17.0, safe optimization. Runtime sources: Kosmos semantic source `28a7dcbb8f79782b70255b7d9cc092ec2b3094d84a4fc2930d58d97a1b49f112`, Horos `31aa79fbb05c5861f81ef79d59710163673af2f8`. The Kosmos source identity binds the authored implementation and compiler before this report is generated. This measurement ran separately from the native/platform qualification suites. These are local samples, not tail-latency or platform-independent claims.

Reproduce with `zig build bench-semantics -Doptimize=safe`. Select one workload with `-Deconomy-workload=scalar_chain`. Every measured realization is checked against the independent direct-native trace, canonical checkpoints and outcomes for the same inputs and controls. The direct-native and bootstrap evaluators are verification dependencies only.

The subsequent Horos capture, nominal-authority fallback, sentinel-array ownership and correspondence-domain corrections culminate at `a58967d541402b3661c05b4d599926114df75123`. The regenerated generic artifact has SHA-256 `428b9cee3ebc1aa18aa91e2bc6fc5272e520dbd75fe0dc1ffa95f1eb7614896f`, still 231,649 bytes. Complete byte comparisons across these corrections show that only the compiler's Horos package identifier changed; the executable, recovery helpers and evidence are identical. The measurements below retain their original Horos revision and artifact identities. They are not a new timing measurement of the corrected compiler.

Each family has three input samples. Generic, specialized and instrumented base execution each have three repetitions per input (nine observations); the direct native and bootstrap paths have one per input. Fixed handler and multi-shot programs vary their prescribed external responses where applicable. Dynamic loops use 16/32/48 iterations; cleanup uses 8/16/24 scopes; retained byte payloads use 1/8/64 KiB. Scalar inputs are 41/60/79; the chains contain 24 and 96 add/xor pairs on that dynamic input. The larger chain extends the original ten-workload suite; all original workloads and their inputs remain.

## Execution

Median milliseconds. This interval includes guest execution and its service events; explicit result observation, guest projection, restore and outer serialization are timed separately.

| Workload | Direct native | Generic bootstrap | Generic base | Specialized base | Instrumented base |
| --- | --- | --- | --- | --- | --- |
| scalar | 0.003 | 1.815 | 0.817 | 0.816 | 0.839 |
| scalar_chain | 0.015 | 83.276 | 19.165 | 18.935 | 19.079 |
| scalar_chain_large | 0.057 | 737.110 | 81.774 | 85.926 | 81.396 |
| dynamic_loop | 0.025 | 145.292 | 48.277 | 43.592 | 48.324 |
| structured | 0.005 | 3.890 | 1.605 | 1.472 | 1.578 |
| repeated_calls | 0.051 | 316.539 | 79.093 | 72.232 | 79.191 |
| higher_order | 0.006 | 3.668 | 1.370 | 1.330 | 1.338 |
| handlers | 0.039 | 188.857 | 37.391 | 37.852 | 37.457 |
| multi_shot | 0.041 | 35.413 | 14.066 | 15.734 | 14.124 |
| long_cleanup | 0.441 | 513.906 | 206.664 | 411.706 | 206.732 |
| retained_bytes | 0.017 | 13.021 | 3.446 | 3.495 | 3.467 |

Specialization removes repeated descriptor interpretation and scalar packing, as independently exercised by `semantic_specialization_tests.zig`. The specialized execution median was lower in these samples for `scalar`, `scalar_chain`, `dynamic_loop`, `structured`, `repeated_calls`, `higher_order`. These timing differences describe these inputs and this execution profile; they do not establish universal speedup.

## Construction and artifacts

Construction and independent source/translation validation are separate. Peak bytes below are requested allocator bytes from construction, excluding allocator metadata and RSS. Construction, preparation, execution and restore have distinct allocation domains; their peaks must not be summed.

The generic artifact is 231,649 bytes, SHA-256 `915f7e5d2de855cfbd052a5e7e82bbe8eb4ff0de3e7f93d34cecef280cc13d95`, source identity `28a7dcbb8f79782b70255b7d9cc092ec2b3094d84a4fc2930d58d97a1b49f112`. Admission took 36.015 ms, with 6,037,702 live and 6,867,722 peak requested bytes. Generic construction took 365.888 ms and independent validation 263.726 ms, with 525,101,083 peak requested bytes. The instrumented artifact is 231,926 bytes; construction took 351.212 ms, admission 14.901 ms, validation 267.771 ms and construction peak was 524,269,436 requested bytes.

| Workload | Specialize ms | Validate ms | Admit ms | Construction peak bytes | Artifact bytes | Executable bytes | Proof bytes | Recovery anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 8802.368 | 5492.277 | 427.556 | 9652137203 | 13663111 | 2529879 | 11043819 | 24 |
| scalar_chain | 9923.101 | 6185.761 | 500.142 | 9831231315 | 19273909 | 2650794 | 16533686 | 24 |
| scalar_chain_large | 9158.998 | 5648.718 | 476.744 | 9654937024 | 32927278 | 2647581 | 30190268 | 24 |
| dynamic_loop | 8990.439 | 5633.621 | 443.468 | 9717263760 | 14303538 | 2547468 | 11666657 | 24 |
| structured | 9080.264 | 5662.761 | 439.797 | 9661177695 | 13931501 | 2543269 | 11298819 | 24 |
| repeated_calls | 9019.315 | 5647.496 | 444.063 | 9716684678 | 14297720 | 2547450 | 11660857 | 24 |
| higher_order | 8880.558 | 5541.068 | 436.063 | 9662804511 | 13941845 | 2535720 | 11316712 | 24 |
| handlers | 11058.376 | 6895.602 | 541.900 | 10123035426 | 21207838 | 2691385 | 18427024 | 24 |
| multi_shot | 8734.311 | 5486.093 | 426.164 | 5613751300 | 14635578 | 2478637 | 12067528 | 24 |
| long_cleanup | 9187.810 | 5734.464 | 452.244 | 9732709747 | 14851883 | 2561347 | 12201123 | 24 |
| retained_bytes | 9043.031 | 5644.350 | 444.550 | 9676457484 | 14589762 | 2550149 | 11950200 | 24 |

Preparation of reusable guest/runtime owners, measured separately in milliseconds:

| Workload | Prepare generic | Prepare specialized | Prepare instrumented |
| --- | --- | --- | --- |
| scalar | 0.033 | 0.004 | 0.003 |
| scalar_chain | 0.060 | 0.028 | 0.027 |
| scalar_chain_large | 0.148 | 0.101 | 0.097 |
| dynamic_loop | 0.035 | 0.011 | 0.008 |
| structured | 0.028 | 0.004 | 0.003 |
| repeated_calls | 0.042 | 0.011 | 0.009 |
| higher_order | 0.048 | 0.006 | 0.008 |
| handlers | 0.138 | 0.096 | 0.082 |
| multi_shot | 0.091 | 0.036 | 0.031 |
| long_cleanup | 0.064 | 0.018 | 0.014 |
| retained_bytes | 0.084 | 0.027 | 0.027 |

## Publication, restoration and switching

Median milliseconds; `G/S` means generic/specialized on the restricted base. Guest hydration and outer restore are different operations. Outer restore includes exact artifact admission and reconstruction checks. Switch observations use the in-memory publication owner and exclude network transport, durable SQLite publication and external authority work.

| Workload | Start G/S | Guest projection G/S | Guest restore G/S | Outer checkpoint G/S | Outer restore G/S | Switch G→S / S→G |
| --- | --- | --- | --- | --- | --- | --- |
| scalar | 0.156 / 0.521 | 0.741 / 0.761 | 0.055 / 0.400 | 1.392 / 3.840 | 2.081 / 5.011 | 6.234 / 5.909 |
| scalar_chain | 0.206 / 0.666 | 0.873 / 0.837 | 0.077 / 0.473 | 1.582 / 4.197 | 2.405 / 5.618 | 7.042 / 6.534 |
| scalar_chain_large | 0.316 / 0.780 | 1.916 / 1.943 | 0.159 / 0.475 | 1.922 / 4.650 | 2.954 / 6.268 | 8.396 / 8.079 |
| dynamic_loop | 0.257 / 0.699 | 0.827 / 0.824 | 0.069 / 0.468 | 1.486 / 3.905 | 2.192 / 5.141 | 6.623 / 6.084 |
| structured | 0.171 / 0.530 | 0.790 / 0.803 | 0.063 / 0.388 | 1.516 / 3.991 | 2.262 / 5.136 | 6.433 / 6.027 |
| repeated_calls | 0.248 / 0.699 | 5.269 / 5.872 | 0.128 / 0.531 | 4.835 / 11.205 | 8.740 / 15.871 | 8.601 / 7.877 |
| higher_order | 0.169 / 0.536 | 0.887 / 0.907 | 0.059 / 0.388 | 1.641 / 4.284 | 2.456 / 5.495 | 6.565 / 5.889 |
| handlers | 0.148 / 0.529 | 2.669 / 2.701 | 0.134 / 0.589 | 4.969 / 10.967 | 7.397 / 14.003 | 7.808 / 7.333 |
| multi_shot | 0.123 / 0.459 | 9.408 / 9.537 | 0.097 / 0.433 | 1.484 / 3.839 | 2.213 / 5.069 | 7.360 / 6.814 |
| long_cleanup | 0.199 / 0.642 | 112.157 / 112.491 | 1.365 / 1.758 | 11.440 / 23.746 | 17.013 / 30.084 | 45.252 / 45.209 |
| retained_bytes | 0.202 / 0.603 | 1.405 / 1.414 | 0.072 / 0.421 | 2.559 / 6.153 | 3.833 / 7.877 | 6.727 / 6.275 |

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
| long_cleanup | 365 | 650656 / 1662150 | 24 | 1038950 / 1167080 | 4866145 / 4830074 | 981 | 8477 / 6974 |
| retained_bytes | 13 | 13514 / 12906 | 0 | 311357 / 292714 | 1065153 / 892542 | 79 | 134993 / 133667 |

## Amortization and limits

The following estimate divides construction + independent validation + artifact admission + the specialized-minus-generic preparation cost by the mean generic-minus-specialized start-plus-execute time over the equally weighted three-input workload. A nonpositive saving has no measured finite break-even. The run count is the first integer strictly exceeding cost divided by saving. It assumes an available generic artifact, reusable prepared owners and stable timing; host variation and small timing differences can dominate the estimate.

| Workload | Initial incremental cost ms | Mean start + execute G ms | Mean start + execute S ms | Saving ms | Estimated new-session runs |
| --- | --- | --- | --- | --- | --- |
| scalar | 14722.172 | 0.982 | 1.373 | -0.391 | No measured break-even |
| scalar_chain | 16608.972 | 19.527 | 19.787 | -0.260 | No measured break-even |
| scalar_chain_large | 15284.413 | 82.106 | 87.090 | -4.985 | No measured break-even |
| dynamic_loop | 15067.504 | 48.639 | 43.930 | 4.709 | 3,200 |
| structured | 15182.799 | 1.777 | 2.006 | -0.229 | No measured break-even |
| repeated_calls | 15110.842 | 81.904 | 75.163 | 6.741 | 2,242 |
| higher_order | 14857.647 | 1.547 | 1.869 | -0.322 | No measured break-even |
| handlers | 18495.837 | 37.587 | 38.529 | -0.943 | No measured break-even |
| multi_shot | 14646.513 | 14.201 | 16.220 | -2.019 | No measured break-even |
| long_cleanup | 15374.472 | 226.962 | 432.725 | -205.763 | No measured break-even |
| retained_bytes | 15131.874 | 3.661 | 4.095 | -0.434 | No measured break-even |

These estimates exclude cache hits, storage, transfer, model-token cost and observation/publication costs, including outer restoration. Those costs can erase a saving. No timing result is an unconditional specialization policy.

The source builders preserve sharing at ordinary transitions; table tests measure 30/38/46 copied fields at 64/256/1024 entries and zero constructed blob bytes for a path update. These are concrete representation observations, not RSS measurements or universal complexity proofs. Instrumentation retains separate events and storage counters; disabled hooks are removed from the generic artifact.

Native process RSS, WASM timing, network transfer latency and live model token costs were not measured by this executable. Platform conformance and process mobility are separate qualification results. Deterministic model-action fixtures establish available choices, not autonomous model efficacy.

Raw output: 421 JSONL records, SHA-256 `e003f7ad6782b83b4d98f76e2401499fd342529753d7a6f0e3ea99042209d7d5` (`kosmos-single-slot-full.stdout`). The earlier baseline identifiers remain in this document's Git history.
