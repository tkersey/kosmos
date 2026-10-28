# Semantic economy measurements

Measured 2026-10-18 on Apple M2 Pro, macOS 27.2 (26B5112a), Zig 0.17.0, safe optimization. Runtime sources: Kosmos host facade `6874a7d832e8deca665db57b853c53e4926da18b`, semantic source `ae2e86f57d67fe6b1ac568ef703013b124f279b06b1a3e3b38415f4fcb637af5`, Horos `592eb0839326f2d8a423b59ce2746ab18ef5136a`. The Kosmos source identity binds the authored implementation and compiler before this report is generated. This measurement used a separate benchmark invocation after complete qualification; no other session-owned qualification or review process was active. These are local samples, not tail-latency or platform-independent claims.

Reproduce with `zig build bench-semantics -Doptimize=safe`. Select one workload with `-Deconomy-workload=scalar_chain`. Every measured realization is checked against the independent direct-native trace, canonical checkpoints and outcomes for the same inputs and controls. The direct-native and bootstrap evaluators are verification dependencies only, fetched from immutable Kosmos `62279bce8e916e7fe613fe4575b3bc12e530596f` with package identity `kosmos-8.0.0-vcJNB7_PDwCsxCmIN8VIVZsi9fW8qHX7Y5xesXeS6Kn5`. They retain that historical implementation and storage; no copied current engine supplies the reference. The reference shares the selected Horos admission dependency, so this comparison is independent execution evidence, not independent admission evidence.

Each family has three input samples. Generic, specialized and instrumented base execution each have three repetitions per input (nine observations); the direct native and bootstrap paths have one per input. Fixed handler and multi-shot programs vary their prescribed external responses where applicable. Dynamic loops use 16/32/48 iterations; cleanup uses 8/16/24 scopes; retained byte payloads use 1/8/64 KiB. Scalar inputs are 41/60/79; the chains contain 24 and 96 add/xor pairs on that dynamic input. The larger chain extends the original ten-workload suite; all original workloads and their inputs remain.

## Execution

Median milliseconds. This interval includes guest execution and its service events; explicit result observation, guest projection, restore and outer serialization are timed separately.

| Workload | Direct native | Generic bootstrap | Generic base | Specialized base | Instrumented base |
| --- | --- | --- | --- | --- | --- |
| scalar | 0.004 | 2.065 | 0.795 | 0.817 | 0.810 |
| scalar_chain | 0.017 | 84.256 | 19.346 | 19.359 | 19.499 |
| scalar_chain_large | 0.056 | 735.075 | 82.156 | 86.108 | 82.665 |
| dynamic_loop | 0.032 | 147.199 | 49.016 | 42.839 | 49.188 |
| structured | 0.007 | 4.208 | 1.623 | 1.462 | 1.618 |
| repeated_calls | 0.055 | 341.153 | 78.569 | 71.573 | 78.505 |
| higher_order | 0.006 | 3.853 | 1.332 | 1.333 | 1.342 |
| handlers | 0.045 | 202.729 | 37.325 | 37.907 | 37.421 |
| multi_shot | 0.048 | 54.955 | 13.855 | 15.601 | 13.913 |
| long_cleanup | 0.418 | 1162.872 | 198.547 | 389.646 | 200.063 |
| retained_bytes | 0.018 | 13.347 | 3.431 | 3.458 | 3.413 |

Specialization removes repeated descriptor interpretation and scalar packing, as independently exercised by `semantic_specialization_tests.zig`. The specialized execution median was lower in these samples for `dynamic_loop`, `structured`, `repeated_calls`. These timing differences describe these inputs and this execution profile; they do not establish universal speedup.

## Construction and artifacts

Construction and independent source/translation validation are separate. Peak bytes below are requested allocator bytes from construction, excluding allocator metadata and RSS. Construction, preparation, execution and restore have distinct allocation domains; their peaks must not be summed.

The generic artifact is 228,187 bytes, SHA-256 `2866f4660fa7f022e74db3f3ac9a42a995d999a4816be89d9618d5ba7e8cdd85`, source identity `ae2e86f57d67fe6b1ac568ef703013b124f279b06b1a3e3b38415f4fcb637af5`. Admission took 29.090 ms, with 5,986,554 live and 6,816,574 peak requested bytes. Generic construction took 258.081 ms and independent validation 166.264 ms, with 648,998,667 peak requested bytes. The instrumented artifact is 228,464 bytes; construction took 231.824 ms, admission 10.944 ms, validation 166.970 ms and construction peak was 649,286,592 requested bytes.

| Workload | Specialize ms | Validate ms | Admit ms | Construction peak bytes | Artifact bytes | Executable bytes | Proof bytes | Recovery anchors |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 4036.094 | 2370.041 | 168.318 | 9509887531 | 13587601 | 2512191 | 10986367 | 14 |
| scalar_chain | 4170.886 | 2444.574 | 181.803 | 9733948913 | 18390991 | 2634659 | 15667273 | 14 |
| scalar_chain_large | 4043.837 | 2311.931 | 189.929 | 9698588857 | 29554501 | 2631368 | 26834074 | 14 |
| dynamic_loop | 3959.309 | 2347.302 | 171.351 | 9596824242 | 14141310 | 2529799 | 11522468 | 14 |
| structured | 4109.435 | 2375.733 | 169.443 | 9586910165 | 13829767 | 2525602 | 11215122 | 14 |
| repeated_calls | 4011.150 | 2339.312 | 170.684 | 9596408849 | 14135447 | 2529781 | 11516623 | 14 |
| higher_order | 3901.997 | 2312.459 | 166.744 | 9504880745 | 13822459 | 2518036 | 11215380 | 14 |
| handlers | 4356.877 | 2556.157 | 190.339 | 9909105677 | 20353835 | 2675189 | 17589587 | 14 |
| multi_shot | 3912.560 | 2287.715 | 165.882 | 9473781075 | 14361323 | 2460973 | 11811307 | 14 |
| long_cleanup | 4062.047 | 2354.020 | 171.370 | 9614833145 | 14615791 | 2543680 | 11983068 | 14 |
| retained_bytes | 3963.786 | 2351.525 | 170.515 | 9601596679 | 14382569 | 2533055 | 11760471 | 14 |

Preparation of reusable guest/runtime owners, measured separately in milliseconds:

| Workload | Prepare generic | Prepare specialized | Prepare instrumented |
| --- | --- | --- | --- |
| scalar | 0.053 | 0.003 | 0.003 |
| scalar_chain | 0.054 | 0.028 | 0.027 |
| scalar_chain_large | 0.140 | 0.103 | 0.094 |
| dynamic_loop | 0.041 | 0.011 | 0.008 |
| structured | 0.028 | 0.004 | 0.003 |
| repeated_calls | 0.042 | 0.013 | 0.008 |
| higher_order | 0.035 | 0.006 | 0.008 |
| handlers | 0.145 | 0.096 | 0.086 |
| multi_shot | 0.087 | 0.044 | 0.035 |
| long_cleanup | 0.059 | 0.019 | 0.015 |
| retained_bytes | 0.079 | 0.024 | 0.027 |

## Publication, restoration and switching

Median milliseconds; `G/S` means generic/specialized on the restricted base. Guest hydration and outer restore are different operations. Outer restore includes exact artifact admission and reconstruction checks. Switch observations use the in-memory publication owner and exclude network transport, durable SQLite publication and external authority work.

| Workload | Start G/S | Guest projection G/S | Guest restore G/S | Outer checkpoint G/S | Outer restore G/S | Switch G→S / S→G |
| --- | --- | --- | --- | --- | --- | --- |
| scalar | 0.160 / 0.528 | 0.704 / 0.700 | 0.057 / 0.374 | 0.711 / 1.776 | 1.385 / 2.934 | 5.457 / 5.093 |
| scalar_chain | 0.208 / 0.638 | 0.767 / 0.763 | 0.084 / 0.451 | 0.815 / 1.948 | 1.617 / 3.244 | 5.968 / 5.527 |
| scalar_chain_large | 0.328 / 0.786 | 1.866 / 1.910 | 0.162 / 0.470 | 1.117 / 2.224 | 2.168 / 3.827 | 7.181 / 6.772 |
| dynamic_loop | 0.252 / 0.696 | 0.734 / 0.730 | 0.068 / 0.455 | 0.751 / 1.845 | 1.430 / 2.999 | 5.600 / 5.173 |
| structured | 0.167 / 0.505 | 0.719 / 0.714 | 0.066 / 0.371 | 0.741 / 1.800 | 1.421 / 2.945 | 5.636 / 5.201 |
| repeated_calls | 0.258 / 0.715 | 4.972 / 5.393 | 0.123 / 0.531 | 4.065 / 5.590 | 8.174 / 10.678 | 7.113 / 6.737 |
| higher_order | 0.161 / 0.525 | 0.710 / 0.712 | 0.061 / 0.379 | 0.729 / 1.783 | 1.412 / 2.946 | 5.476 / 5.118 |
| handlers | 0.142 / 0.501 | 0.830 / 0.831 | 0.129 / 0.527 | 0.972 / 2.130 | 1.767 / 3.509 | 6.530 / 6.123 |
| multi_shot | 0.126 / 0.450 | 6.728 / 6.758 | 0.101 / 0.440 | 0.849 / 1.921 | 1.641 / 3.143 | 6.270 / 5.780 |
| long_cleanup | 0.188 / 0.604 | 54.154 / 53.798 | 1.376 / 1.748 | 5.487 / 6.499 | 10.643 / 12.285 | 35.743 / 35.107 |
| retained_bytes | 0.202 / 0.610 | 0.726 / 0.726 | 0.071 / 0.398 | 0.759 / 1.821 | 1.455 / 2.997 | 5.615 / 5.249 |

## Physical state and work

Values are maxima across the three inputs and nine repetitions on each base realization. `G/S` again means generic/specialized. Work counts are logical guest and physical base counts, not time. Effects count dispatched guest requests. Guest checkpoint length is identical across realizations for each matched cut.

| Workload | Guest work | Base work G/S | Effects | Live requested bytes G/S | Peak requested bytes G/S | Guest checkpoint bytes | Outer checkpoint bytes G/S |
| --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 3 | 3123 / 2934 | 0 | 54864 / 48869 | 212278 / 186727 | 79 | 1500 / 1187 |
| scalar_chain | 97 | 90159 / 88486 | 0 | 377783 / 405550 | 742883 / 807194 | 79 | 13280 / 7077 |
| scalar_chain_large | 385 | 358561 / 366223 | 0 | 1436334 / 1394763 | 1880910 / 1817380 | 84 | 49335 / 25126 |
| dynamic_loop | 341 | 336376 / 277540 | 0 | 108848 / 72381 | 371346 / 266186 | 93 | 2864 / 1909 |
| structured | 6 | 6538 / 5689 | 0 | 84130 / 49262 | 267786 / 210300 | 90 | 1939 / 1424 |
| repeated_calls | 389 | 556046 / 490200 | 0 | 717385 / 524237 | 2236575 / 2077793 | 1017 | 5990 / 5035 |
| higher_order | 5 | 5218 / 4830 | 0 | 86087 / 50002 | 263707 / 203900 | 79 | 2144 / 1509 |
| handlers | 110 | 167587 / 158495 | 0 | 384390 / 264266 | 1410478 / 1123140 | 79 | 13096 / 6985 |
| multi_shot | 23 | 53481 / 57472 | 3 | 179916 / 154236 | 267929 / 246512 | 178 | 4479 / 2706 |
| long_cleanup | 365 | 1754508 / 2762441 | 24 | 1012979 / 1125922 | 5486658 / 5180126 | 981 | 8008 / 6505 |
| retained_bytes | 13 | 16787 / 16223 | 0 | 141018 / 114235 | 526450 / 429249 | 79 | 3524 / 2199 |

## Amortization and limits

The following estimate divides construction + independent validation + artifact admission + the specialized-minus-generic preparation cost by the mean generic-minus-specialized start-plus-execute time over the equally weighted three-input workload. A nonpositive saving has no measured finite break-even. The run count is the first integer strictly exceeding cost divided by saving. It assumes an available generic artifact, reusable prepared owners and stable timing; host variation and small timing differences can dominate the estimate.

| Workload | Initial incremental cost ms | Mean start + execute G ms | Mean start + execute S ms | Saving ms | Estimated new-session runs |
| --- | --- | --- | --- | --- | --- |
| scalar | 6574.404 | 0.978 | 1.362 | -0.384 | No measured break-even |
| scalar_chain | 6797.237 | 19.585 | 19.972 | -0.388 | No measured break-even |
| scalar_chain_large | 6545.661 | 82.545 | 87.098 | -4.553 | No measured break-even |
| dynamic_loop | 6477.932 | 49.195 | 43.933 | 5.261 | 1,232 |
| structured | 6654.588 | 1.785 | 1.985 | -0.200 | No measured break-even |
| repeated_calls | 6521.117 | 81.465 | 74.379 | 7.086 | 921 |
| higher_order | 6381.171 | 1.503 | 1.870 | -0.368 | No measured break-even |
| handlers | 7103.325 | 37.498 | 38.423 | -0.925 | No measured break-even |
| multi_shot | 6366.114 | 13.969 | 16.133 | -2.165 | No measured break-even |
| long_cleanup | 6587.397 | 222.376 | 415.066 | -192.691 | No measured break-even |
| retained_bytes | 6485.771 | 3.893 | 4.369 | -0.476 | No measured break-even |

These estimates exclude cache hits, storage, transfer, model-token cost and observation/publication costs, including outer restoration. Those costs can erase a saving. No timing result is an unconditional specialization policy.

The source builders preserve sharing at ordinary transitions; table tests measure 30/38/46 copied fields at 64/256/1024 entries and zero constructed blob bytes for a path update. These are concrete representation observations, not RSS measurements or universal complexity proofs. Instrumentation retains separate events and storage counters; disabled hooks are removed from the generic artifact.

Projection-cache counters unavailable in the immutable reference are emitted as `null`, not invented zeroes. Native process RSS, WASM timing, network transfer latency and live model token costs were not measured by this executable. Platform conformance and process mobility are separate qualification results. Deterministic model-action fixtures establish available choices, not autonomous model efficacy.

Raw output: 421 JSONL records, SHA-256 `ea6f2e0e1b16674a2759a1e5ee8c115831e60835fd2e511583bd5a77da5f227b` (`kosmos-6874a7d-economy.stdout`). The earlier baseline identifiers remain in this document's Git history.

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

## Direct frame traversal, 2026-10-27

The matched parent is Kosmos `6dd76e2c0ef62496b7c92b868a4bd656381ccd03`,
semantic source `db1f6e65bd0a4a7272f21971670fff474c9c0c0a272de69ca46e346894b397f3`.
The candidate semantic source is
`08c48a517383d1f8addd8175dcf73e4542cb3b781fba74ba3ba5d3f8fbfe8f6a`, with packaged
artifact `b288ae2f5b94efc1c1ed263a83051ebd539202ad160a778337607fd0d0169aa8`.
Both use Horos `013d783dd45a7994f1c888f66f98a7003c173a79`, exact Zig 0.17.0,
native `safe`, Apple M2 Pro and macOS 27.2. The dependency package is
`horos-8.0.0-flclaFkFVQBKG0Iqo_c4I6U8mhZqTO358ywkjB63B6Sg`.

Reproduction uses `zig build bench-semantics -Doptimize=safe
-Deconomy-workload=multi_shot` at each revision. Two invocations per revision ran
in parent/candidate order, without other session-owned qualification or review
processes during measurement. Each invocation retains the three inputs and three
execution repetitions per input: eighteen observations per base realization below.
The second pair reused the exact built executables. Construction/admission medians
have only two observations. These are local measurements, not tail estimates or
an isolated attribution of every timing difference to cloning.

The unchanged 316-byte guest image has identity
`4e6b620fb5119075c9acd72816ca731a9965231ab468c82d21b8d77b9470ce15`. Every realization
compares complete canonical checkpoints and outcomes with the immutable native
reference for identical controls. Each execution retains 23 guest transitions,
three effects and six cuts. The full benchmark, including its sixteen generated
scalar edits and independently validated derived candidate, completes.

### Focused frame work

`check-semantics` includes the dynamic frame driver in `frame_tests.zig`. It builds
bindings, mapping and prefix before a yield, then measures discovery and rebasing
between yields, before public observation. One pair of compiled helper images is
reused across the six inputs. Keys are spaced by 1024; raw bits are a fixed
nontrivial pattern plus slot ordinal. Ordinary references alternate between 7 and
8. The matching map is `{7 -> 8, 8 -> 9}`; the disjoint map is `{99 -> 100}`.
The reference prefix contains 91. Both implementations execute on the actual base.

| Slots | Reference occurrences | Mapping | Discovery transitions, public/direct | Rebase transitions, public/direct |
| --- | --- | --- | ---: | ---: |
| 8 | 2 | matching | 955 / 142 | 2401 / 258 |
| 64 | 2 | matching | 8146 / 646 | 23366 / 1502 |
| 256 | 2 | matching | 32892 / 2374 | 100924 / 5734 |
| 16 | 16 | matching | 1901 / 881 | 4812 / 986 |
| 64 | 2 | disjoint | 8146 / 646 | 23350 / 1448 |
| 64 | 0 | matching | 8181 / 575 | 23426 / 1402 |

The tests assert lower work rather than fixed totals. They also compare exact
ordered references and public activations, retain predecessor observations, and
inspect raw tags, schemas and all bits separately from public projection. Additional
cases cover empty, partial and self maps, one-step replacement, owner order,
identity-domain collisions, repeated aliases and sparse u64 boundary keys.

Source-to-lowered-function counters observe conversion entries in the public
composition and zero such entries during either direct helper interval. A separate
emitted-call-graph probe found projection and scalar packing reachable from the
parent clone scan, and projection, packing and hydration reachable from its remap.
None is reachable from either candidate clone entry, although those functions
remain emitted for other consumers. Raw-slot observations establish preservation
independently of these counters. Unchanged tree paths are reused by construction;
no native pointer-identity or zero-allocation claim follows.

### Integrated costs

Medians; times are milliseconds. Requested allocation excludes allocator metadata
and RSS. The existing meter exposes live/peak bytes, not allocation-call counts.

| Realization | Base transitions, parent/candidate | Execution ms, parent/candidate | Live bytes, parent/candidate | Peak bytes, parent/candidate |
| --- | ---: | ---: | ---: | ---: |
| Generic | 53852 / 53476 | 13.854 / 13.729 | 181824 / 182571 | 270900 / 271646 |
| Specialized | 64979 / 64669 | 17.441 / 17.353 | 166173 / 165999 | 253014 / 252851 |
| Instrumented | 54234 / 53858 | 13.967 / 13.808 | 182413 / 182571 | 271488 / 271646 |

The deterministic integrated work reduction is 0.70% generic and 0.48% specialized;
this fixed guest does not establish scaling with captured-frame width. Generic
peak allocation increases by 746 bytes (0.28%), while specialized peak decreases
by 163 bytes. The two matched runs show no material execution or allocation
regression. Integrated timing differences are small relative to local variation; these
samples establish no wall-time speedup. Projection and restoration remain
separately measured observations.

| Realization | Guest projection ms, parent/candidate | Guest restore ms, parent/candidate | Outer checkpoint ms, parent/candidate | Outer restore ms, parent/candidate |
| --- | ---: | ---: | ---: | ---: |
| Generic | 7.030 / 7.051 | 0.105 / 0.105 | 0.896 / 0.902 | 1.734 / 1.712 |
| Specialized | 7.025 / 7.056 | 0.545 / 0.553 | 2.312 / 2.273 | 3.712 / 3.726 |

Restore peaks remain 29,874 requested bytes generic and 22,116 specialized.
Outer checkpoints remain specific to their producing artifact; their bytes are
not a cross-artifact equivalence test.

### Artifact and construction tradeoffs

The generic package grows from 275,293 to 276,094 bytes. Admission retains
7,878,994 bytes versus 7,842,128, with peak 8,910,846 versus 8,873,980. Its observed
admission median rises from 35.173 to 37.707 ms. Generic construction changes from
294.977 to 312.031 ms, independent validation from 201.107 to 219.848 ms, and
construction peak from 852,233,177 to 850,086,812 requested bytes.

| Specialized multi-shot artifact | Parent | Candidate |
| --- | ---: | ---: |
| Construction ms | 5955.750 | 5982.971 |
| Independent validation ms | 3516.132 | 3515.145 |
| Construction peak requested bytes | 10050470069 | 9222205592 |
| Artifact bytes | 19180715 | 19168148 |
| Executable bytes | 3352149 | 3350503 |
| Evidence bytes | 15701036 | 15690391 |
| Recovery anchors | 14 | 14 |

The initial candidate exposed a separate cost in compact relation-evidence
decoding: each reconstructed module was decoded and then copied in full. The
larger source exhausted the existing 64-million work budget during sixteen-edit
validation. Retaining decoded source backing and
ordinary rule storage removes that duplicate copy. The work budget, sixteen edits,
canonical delta checks and independent relation checks are unchanged. Encoded
specialization proofs continue through the existing Horos decoder.

For the generated sixteen-edit candidate, validation peak drops from 2,207,225,264
to 1,872,651,074 requested bytes while its median time changes from 978.402 to 988.839 ms.
Derivation peak increases from 2,229,827,832 to 2,264,720,023 bytes; its artifact,
executable and evidence sizes change from 709188/96136/485556 to
711871/96997/487654 bytes. These construction costs are separate from ordinary
guest execution and must not be added to its live/peak allocation figures.

A nonempty reference map still scans every retained binding. This change makes no
constant-time instantiation, changed-only scan, universal speedup or zero-allocation
claim. The PR records qualification and review results for its delivered head.
