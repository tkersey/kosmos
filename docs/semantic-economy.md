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

## Request-checked diagnostics, 2026-11-05

Measured with the implementation accompanying this report on Apple M2 Pro,
macOS 27.3 (26C5035r), exact Zig 0.17.1, native aarch64 `safe`. Zig reported CPU
model `apple_a15`. No other session-owned qualification or benchmark ran
concurrently. The command completed with exit 0 in 104.97 seconds including
compilation and emitted 460 JSONL records:

```sh
/usr/bin/time -p zig build bench-semantics -Doptimize=safe -Deconomy-workload=diagnostics
```

The generic semantic source is
`08c48a517383d1f8addd8175dcf73e4542cb3b781fba74ba3ba5d3f8fbfe8f6a`, with packaged
artifact `c5beb14f0f28a3fb4bf8a7f2839829fc99e7e4e3fee3ef06478f5697d56e665a`.
These identities bind the existing runtime; replay programs are constructed
separately by the diagnostic fixtures. The independent native evaluator remains
the immutable reference identified above. Process and OS cache state were not
controlled. Times use the awake clock, recorded in nanoseconds. Allocation
meters count requested bytes over the process GPA, excluding metadata and RSS.
The native baseline and paired Kosmos execution use that same backing allocator;
fixture preparation and retained trace storage use a separate arena. This run
supersedes the initial measurements, whose native baseline incorrectly used the
fixture arena for measured execution. All 460 records match the prior
run after excluding timing fields; timing differences across runs are not
attributed to a runtime speedup.

There are three samples per family, with 2, 4 and 8 repeated request occurrences.
Scalar payloads contain one u64; structured payloads contain 4, 16 and 64 u64
fields; blob payloads contain 64, 256 and 1,024 bytes. The aliased graph retains
four references to one computation closure capturing the blob across requests;
its native checkpoint must contain four references to the same node. All
requests receive unit replies. Width and request count vary together outside
the scalar family, so these samples do not isolate their individual scaling.

Each sample runs matching, first-request payload mismatch and last-request
payload mismatch cases in summary and snapshot modes, three times each: 216
replay observations. Mismatches change the last payload byte. Construction and
preparation happen once per fixture and capture mode; the immutable prepared
program serves all cases and repetitions. Plain and instrumented guest runs
have three repetitions each, with order alternated; the independent native
reference runs once per sample. Retention comparisons have three repetitions
of three queries each. Restore measurements have one sample per fixture and
capture mode, after suspension at 128 base transitions.

### Replay output and execution

`Match / first / later` gives median summary execution milliseconds, including
request and terminal comparison. Output and base-work columns compare matching
summary / snapshot modes, which intentionally disclose different results.
Guest input includes the blob length prefix; replay input also includes the
bound transcript and expected terminal observation.

| Family | Payload elements or bytes | Requests | Guest input bytes | Replay input bytes | Match / first / later ms | Output bytes, summary / snapshot | Base transitions, summary / snapshot |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| scalar | 1 | 2 | 8 | 121 | 1.181 / 0.635 / 0.952 | 88 / 306 | 4773 / 4920 |
| scalar | 1 | 4 | 8 | 157 | 1.911 / 0.650 / 1.659 | 88 / 392 | 7820 / 8003 |
| scalar | 1 | 8 | 8 | 229 | 3.391 / 0.657 / 3.140 | 88 / 564 | 14231 / 14486 |
| structured fields | 4 | 2 | 32 | 193 | 1.170 / 0.692 / 0.983 | 88 / 347 | 4727 / 4884 |
| structured fields | 16 | 4 | 128 | 762 | 1.892 / 0.899 / 1.891 | 88 / 530 | 7906 / 8099 |
| structured fields | 64 | 8 | 512 | 4774 | 3.535 / 1.755 / 4.239 | 88 / 1086 | 14941 / 15206 |
| blob | 64 | 2 | 65 | 292 | 1.171 / 0.742 / 1.046 | 88 / 380 | 4688 / 4845 |
| blob | 256 | 4 | 258 | 1412 | 1.851 / 1.073 / 2.090 | 88 / 660 | 7704 / 7897 |
| blob | 1024 | 8 | 1026 | 9400 | 3.329 / 2.414 / 4.975 | 88 / 1600 | 14019 / 14284 |
| aliased graph | 64 | 2 | 65 | 292 | 1.910 / 1.087 / 1.421 | 88 / 506 | 8083 / 8294 |
| aliased graph | 256 | 4 | 258 | 1412 | 2.700 / 1.474 / 2.554 | 88 / 786 | 11344 / 11591 |
| aliased graph | 1024 | 8 | 1026 | 9400 | 4.241 / 2.879 / 5.434 | 88 / 1726 | 18001 / 18320 |

Matching summaries were exactly 88 bytes; payload-mismatch summaries were exactly
120 bytes at every size. They contain neither an observation nor a snapshot,
and the executable enforces a 128-byte bound. Snapshot outputs ranged from
295 to 1,733 bytes across all cases. Every snapshot matches the complete
canonical native checkpoint at its terminal or pending boundary. The checks
also require exact mismatch lengths and first differing offset, matching
request counts and native guest-work totals. Resuming each suspended analysis
must produce the same result bytes as uninterrupted execution.

The summary mode emits fewer bytes and performs fewer base transitions on these
fixtures. It does not imply constant total memory: admitted transcripts, private
guest state and evaluator storage remain. For the largest aliased graph,
execution peak was 148,236 requested bytes in both modes; decoded-output
peak was 0 / 3,816 bytes. The zero refers only to host decoding of the fixed-size
summary; encoded output remains owned by the execution domain. Last-byte
mismatch witnesses scan the differing payload and can cost more than a complete
match, as the larger blob cases show. Early rejection is a separate workload.

### Paired instrumentation and view reuse

Both actual guest realizations match the independent native reference's complete
canonical checkpoints and outcome bytes at every cut, with identical inputs
and controls. For each family's largest sample, the medians are:

| Family | Execution ms, plain / instrumented | Base transitions, plain / instrumented |
| --- | ---: | ---: |
| scalar | 7.806 / 7.998 | 21857 / 22463 |
| structured fields | 8.428 / 8.686 | 24665 / 25271 |
| blob | 8.387 / 8.591 | 24665 / 25271 |
| aliased graph | 14.702 / 14.996 | 51402 / 52184 |

These guest runs are separate from the pure replay program. Their runner also
measures observation encoding, canonical guest projection, trace projection,
guest restore, capsule encoding and outer restore. The samples show additional
instrumentation work, without establishing a general overhead bound.

Retention compares identical ordered result bytes for three targets under the
same complete metadata disclosure, with no values, blob payloads or snapshot.
On the largest aliased graph, one capture reused for three queries took a median
10,792 ns for admission plus traversal, versus 30,500 ns for three captures.
Both performed 3,000 query base transitions and had a 10,192-byte capture peak.
Query encoding/execution/result-extraction medians were 606,376 / 598,917 ns.
A separate required-admission probe took 9,375 ns on its single sample;
`captureDetailed` still admitted every capture. Reuse avoids two captures within
one explicit owning lifetime. No public session abstraction, view cache or
production-path optimization was introduced.

### Stage boundaries and limits

The largest aliased-graph matching sample illustrates the separately measured
stages below. Execution-stage values are three-run medians; construction,
preparation, checkpoint and restore each have one observation per mode.

| Stage | Milliseconds, summary / snapshot |
| --- | ---: |
| Start admission, construction and lowering | 81.351 / 81.416 |
| Program preparation | 6.899 / 6.972 |
| Session start admission | 0.030 / 0.032 |
| Execution, comparison and optional projection | 4.241 / 4.347 |
| Result encoding | 0.001 / 0.002 |
| Suspended analysis checkpoint | 0.027 / 0.025 |
| Suspended analysis restore | 0.059 / 0.058 |

Replay start admission, source construction and lowering share an interval.
Execution includes guest steps, request/terminal comparison and optional snapshot
projection. `Session.bytes` result encoding is timed separately; subsequent host
result decoding has its own allocation domain. View capture combines required
admission and traversal; the separate admission probe is not subtracted from it.
Query encoding, execution and result extraction share one interval. These
boundaries avoid attributing precision the API does not expose.

The largest aliased graph's matching canonical guest checkpoint was
1,101 bytes; its suspended analysis checkpoint was 9,646 bytes. The latter
contains the replay computation's own progress and transcript. Mismatch rows
report the actual native pending-cut checkpoint size. Input, construction,
preparation, execution, decoded output, view capture, query, checkpoint and
restore domains retain separate live/peak requested-byte figures; their peaks
must not be summed into a fictitious concurrent peak.

Publication timing covers in-memory `RuntimeCapsule` encoding at a guest cut,
excluding durable publication, network dispatch and retry. This executable
provides no WASM timing; native/WASM correctness and publication failure behavior
are separate qualification results. Three local repetitions do not establish
tail latency, universal throughput, constant memory or work proportional only
to disclosed data. The result supports the bounded-summary design and reuse of
an existing captured view, without an additional production optimization claim.

Raw output: `kosmos-replay-diagnostics-gpa.jsonl`, 460 records, SHA-256
`e1ea86917cbeb71485fd6bd73c2c0952cd486dcaa26ade6c1869d708dbfc8074`.

## Known terminator dispatch (November 6, 2026)

The staged block leaf now passes the selected block's complete terminator to
`step.control_at`. Both control entrances use the same source emitter and
operation rules. The generic entrance retains its original discovery sequence;
the selected entrance reads dynamic frame values and capabilities normally.
No extra runtime worker, handler-instance cache or changed specialization policy
is involved. The original generic base-transition counts below are unchanged.

The comparison retains Kosmos `afde6a77eab528d2adf4b6692f766c38e745e158` as the
old production source. Both checkouts use Horos
`fbbc83e6e5ad4c4f92081c811148ba9ee6b1e014`, package
`horos-8.0.0-flclaIItVgDcvEsGli63_QQ_OykDT6dVbRvtdijaJiyZ`, Zig 0.17.1,
`safe`, native aarch64 macOS on Apple M2 Pro, Darwin 27.3.0. The revised source
digest is `5b6b77d09e2085b664710f1316855b13b7e89e5f05894995d80cba0a7c2a2f49`;
its regenerated generic artifact is 276,698 bytes, digest
`1760759ab06ccc7ce8a1ef9d4a7c47dd19829ed91680289151a9bc438fee255f`.
The preceding generic artifact was 276,094 bytes. The PR identifies the final
qualified commit; test and documentation edits do not change this source digest.

### Executed descriptor work

The focused observer follows source-function derivation and lowering into the
actual executing control function. It counts only block-table accesses and
terminator-union selections using their lowered schemas. Dynamic condition-byte
reads and handler-instance resolution remain necessary and are excluded.
For loop inputs `(0,91)`, `(1,12)`, `(4,91)` and `(4,12)`, revised generic
execution and the previous specialized execution perform respectively 3, 5, 11
and 11 descriptor lookups and selections; the revised specialized route performs
zero of each. Its base transitions are
5,781 / 11,400 / 28,257 / 28,257, compared with the previous specialized
5,890 / 11,611 / 28,774 / 28,774. The tests preserve complete canonical native
observations, guest work and directly specified XOR results.

A nested Reader witness installs the same descriptor twice with dynamic values
`(10,100)`, `(7,900)` and `(100,10)`. After yielding under the inner installation,
it reads the retained outer capability and returns 10, 7 and 100. Both entrances
match the independent native evaluator before and after restoration. Generic
execution performs 10 descriptor lookups and selections; specialized execution
performs zero, compared with 10 of each in the previous specialized execution.
Specialized base work falls from 21,812 to 21,683. This witness establishes
receiver identity and descriptor removal,
not a speedup over generic execution: its base work is 19,090 generic versus
21,683 specialized. A one-key-per-function policy retains executed tag selections
while preserving observations; a root work budget of one rejects specialization.
A well-formed carried branch-descriptor mutation fails independent validation.

### Matched execution samples

The existing benchmark ran three repetitions for each of three input samples,
with identical guest bytes, inputs and observation schedules in both checkouts.
Execution medians below exclude construction, validation, preparation and restore.
The loop has 16/32/48 iterations and accumulators 41/60/79. Its 134-byte guest
has identity `e4a797218ba4aeafbc5600d7251eeb73b60b4b3eb8c6d4ead5d4197658466365`.
The 536-byte handler guest uses `source.examples.installations(b, 12)`, identity
`62a5a7fa7f52ba276ea523b4a89a29cc249bd25f34003a13b0879f147882d2ef`; its three
samples have identical inputs, so its timing is the median of all nine runs.

| Workload | Guest work, all subjects | Generic base work, old = new | Specialized base work, old → new | Generic execution ms, old → new | Specialized execution ms, old → new |
| --- | ---: | ---: | ---: | ---: | ---: |
| loop 16 | 117 | 114885 | 99454 → 97713 | 25.958 → 25.662 | 23.075 → 21.660 |
| loop 32 | 229 | 226491 | 195550 → 192177 | 50.912 → 50.229 | 45.110 → 42.944 |
| loop 48 | 341 | 338367 | 291933 → 286928 | 75.573 → 75.379 | 67.141 → 64.285 |
| 12 installations | 110 | 168357 | 163079 → 162438 | 37.023 → 37.015 | 37.943 → 37.644 |

The incremental work reduction is about 1.7% for the loop and 0.4% for the
handler workload. The handler specialization remains slower than generic in
these samples. Neither compilation nor these measurements authorize adoption
of a runtime or replacement of saved tasks.

### Construction, space and recovery

Construction and independent validation each have one timed observation per
workload and revision. Sizes and key counts describe actual validated artifacts.

| Specialized measure | Loop, old → new | Handlers, old → new |
| --- | ---: | ---: |
| Construction ms | 6071.939 → 6000.544 | 6382.899 → 6786.657 |
| Independent validation ms | 3595.019 → 3567.409 | 3720.185 → 3785.221 |
| Executable bytes | 3418082 → 3431550 | 3587281 → 3618762 |
| Complete artifact bytes | 18921366 → 19043028 | 25372475 → 26128805 |
| Derivation proof bytes | 15376030 → 15484224 | 21657924 → 22382773 |
| Specialization keys | 5066 → 5137 | 5898 → 6095 |
| Maximum keys per function | 128 → 128 | 128 → 128 |
| Residual generic call terms | 101 → 101 | 102 → 102 |
| Construction peak requested bytes | 10254997718 → 10175394400 | 10793985211 → 9992722415 |
| Maximum execution retained bytes | 81034 → 77988 | 219487 → 275192 |
| Maximum execution peak bytes | 273981 → 274070 | 1053883 → 1131008 |
| Maximum guest checkpoint bytes | 93 → 93 | 79 → 79 |
| Maximum outer checkpoint bytes | 1910 → 1910 | 6986 → 6986 |
| Artifact admission ms | 258.938 → 257.349 | 270.894 → 272.508 |
| Specialized preparation ms | 0.010875 → 0.010041 | 0.115375 → 0.114875 |
| Generic preparation ms | 0.011584 → 0.012208 | 0.120417 → 0.119209 |
| Median specialized guest restore ms | 0.566 → 0.569 | 0.665 → 0.671 |
| Median specialized outer restore ms | 3.613 → 3.743 | 4.132 → 4.303 |

The unchanged policy is 8,000,000 work, 128 keys per function and depth 1,024.
Only leaf call proof records with no specialized callee are counted; folded
branch aliases are excluded. These are structural conservative calls, not an
executed fallback count or proof that every such call exhausted a key budget.
The shape row is computed outside construction timing. The observer runs are
separate from these execution timings. Existing generic-base memory maxima
remain 109,463 retained / 343,605 peak bytes for the loop and 389,648 / 1,448,378
for handlers. Generic outer checkpoint maxima remain 2,865 and 13,097 bytes.
Generic construction / validation in the loop invocation measured
301.871 / 203.982 ms before and 304.404 / 201.457 ms after.
Generic construction / validation in the handler invocation measured
288.548 / 199.950 ms before and 289.179 / 200.624 ms after.
Each memory domain has its own lifetime; construction and execution peaks
must not be summed.

The conditional amortization criterion is
`N * (old specialized execution - new specialized execution) > added construction + validation`.
The loop's construction plus validation sample decreased by 99.004 ms,
so this pair has no positive additional construction cost to amortize. For
handlers, added construction plus validation was 468.794 ms and the
nine-run execution-median saving was 0.298667 ms: the condition requires
more than 1569.6 executions. These estimates exclude admission and recovery
and assume the measured savings recur. Single construction samples do not
establish a stable break-even point. Small native samples establish neither
tail latency nor universal speedup. Increased handler retained memory (about
25%) and larger proofs remain material costs; the change preserves optional
specialization and does not make it a default for that workload.

Raw JSONL outputs each contain 62 records; filenames and SHA-256:

- `kosmos-terminator-old-loop-v2.jsonl`: `062d55529fb3cc35161c08a60dab588552078bbb580e86ed804bab3b1b254305`
- `kosmos-terminator-new-loop-v2.jsonl`: `bc47cb9cb5a828c62e20b110045b108bef0d4ffbf82fd2fe06828e83c92a511b`
- `kosmos-terminator-old-handlers-v2.jsonl`: `69385df26213a5a54ac377399d5754d12261566fb4000dc43638b398e418859f`
- `kosmos-terminator-new-handlers-v2.jsonl`: `cb9fb5d77123b49ff3f6fd6fc653ad99b29368114381628c840b4f6ad1fe96dc`
