#!/usr/bin/env bash
set -euo pipefail

tools=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$tools/zig-cache.sh
workflow=$tools/../.github/workflows/runtime-bundle.yml
scratch=$(mktemp -d "${TMPDIR:-/tmp}/zig-cache-test.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
export RUNNER_TEMP=$scratch
export ZIG_GLOBAL_CACHE_DIR=$scratch/zig-global
unset KOSMOS_HOST_TARGET KOSMOS_HOST_CPU KOSMOS_CACHE_BYTES_MAX
failures=0

m1=00000000000000000000000000000001 f1=eaae50b21867a4fc20733d2d7251e2b6
m2=00000000000000000000000000000002 f2=a99b3baeeff2e8f171303f036b0d3707
m3=00000000000000000000000000000003 f3=a625e6377ce995bd1579a3550ec1b100
m4=00000000000000000000000000000004 f4=46db8c643cc4fb63b0585ab7edab3d52
m5=00000000000000000000000000000005
m6=00000000000000000000000000000006
m7=00000000000000000000000000000007 f7=efdb98b0b2f2e4035e7d72d2daa34619
m8=00000000000000000000000000000008 f8=f8e51811854fbb1a0ea0cf0382772caf

fail() {
    printf 'FAIL %s: %s\n' "$scenario" "$1" >&2
    failures=$((failures + 1))
}

mkdir -p -- "$scratch/tools-cache"
(cd "$scratch/tools-cache" && zig run -fstrip --cache-dir .zig-cache/tools "$tools/zig-cache-pairs.zig" -- . < /dev/null)

restored_file() {
    mkdir -p -- "$(dirname "$1")"
    printf '%s' "${2:-$1}" > "$1"
    touch -d @1000000000 -- "$1"
}

restored_manifest() {
    restored_file "$1" ''
    printf '\0' > "$1"
    touch -d @1000000000 -- "$1"
}

record_tree() {
    find .zig-cache -type f ! -path .zig-cache/kosmos-cache-record -printf '%s %P\n' | LC_ALL=C sort \
        > "$scratch/record"
    mv -- "$scratch/record" .zig-cache/kosmos-cache-record
}

begin() {
    scenario=$1
    workspace=$scratch/$scenario
    mkdir -p -- "$workspace"
    cd "$workspace"
    export KOSMOS_CACHE_STATE=$workspace/state
    export GITHUB_OUTPUT=$workspace/output
    : > "$GITHUB_OUTPUT"
    local cache=.zig-cache
    restored_manifest $cache/h/$m1
    restored_manifest $cache/h/$m2
    restored_manifest $cache/h/$m3
    restored_manifest $cache/h/$m4
    restored_manifest $cache/h/$m5
    restored_file $cache/h/$m6 ''
    restored_manifest $cache/h/$m8
    restored_file $cache/h/timestamp
    restored_file $cache/o/$f1/test
    restored_file $cache/o/$f2/test
    restored_file $cache/c/$f3
    restored_file $cache/o/$f4/test
    restored_file $cache/o/$f8/libcompiler_rt.a
    restored_file $cache/o/orphan/test
    restored_file $cache/z/used-zir
    restored_file $cache/z/stale-zir
    restored_file $cache/b/used/builtin.zig
    restored_file $cache/b/stale/builtin.zig
    restored_file $cache/p/used.tar.gz
    restored_file $cache/p/stale.tar.gz
    restored_file $cache/tmp/.tmp-leftover/file
    restored_manifest $cache/native-driver-core/h/$m1
    restored_file $cache/native-driver-core/o/$f1/test
    restored_file $cache/native-driver-core/zig-pkg/used/build.zig
    restored_file $cache/native-driver-core/zig-pkg/stale/build.zig
    restored_manifest $cache/source-examples/h/$m2
    restored_file $cache/source-examples/o/$f2/test
    cp -R -- "$scratch/tools-cache/.zig-cache/tools" $cache/tools
    record_tree
}

track() {
    bash "$script" track "${1:-success}" > "$workspace/report"
}

use() {
    local path
    for path in "$@"; do
        cat -- ".zig-cache/$path" > /dev/null
    done
}

compile() {
    mkdir -p -- ".zig-cache/$(dirname "$1")"
    printf '%s' "${2:-$1}" > ".zig-cache/$1"
}

write_manifest() {
    mkdir -p -- .zig-cache/h
    printf '\0' > ".zig-cache/h/$1"
}

rewrite_unread() {
    compile "$1"
    touch -a -d @1 -- ".zig-cache/$1"
    touch -m -d @1000000000 -- ".zig-cache/$1"
}

run() {
    bash "$script" "$1" > "$workspace/report"
}

expect_saved() {
    if [[ "$(tail -n 1 "$GITHUB_OUTPUT")" != "save=$1" ]]; then
        fail "expected save=$1"
        cat "$workspace/report" >&2
    fi
}

expect_present() {
    local path
    for path in "$@"; do
        [[ -e ".zig-cache/$path" ]] || fail "missing $path"
    done
}

expect_absent() {
    local path
    for path in "$@"; do
        [[ ! -e ".zig-cache/$path" ]] || fail "retained $path"
    done
}

expect_report() {
    grep -Fq -- "$1" "$workspace/report" || {
        fail "report lacks: $1"
        cat "$workspace/report" >&2
    }
}

expect_recorded() {
    if ! cmp -s .zig-cache/kosmos-cache-record <(
        find .zig-cache -type f ! -path .zig-cache/kosmos-cache-record -printf '%s %P\n' | LC_ALL=C sort
    ); then
        fail "the saved tree differs from its record"
    fi
}

begin pairs
track
if [[ "$(< "$KOSMOS_CACHE_STATE/tracking")" != on ]]; then
    printf 'Access-time tracking is unavailable on this filesystem; cannot test pruning.\n' >&2
    exit 1
fi
expect_report 'Compiler cache restored (success)'
expect_absent kosmos-cache-record
use h/$m1 h/$m2 o/$f2/test c/$f3 z/used-zir b/used/builtin.zig p/used.tar.gz \
    native-driver-core/h/$m1 native-driver-core/zig-pkg/used/build.zig
run admit
expect_saved true
expect_recorded
expect_present h/$m1 o/$f1/test h/$m2 o/$f2/test h/$m3 c/$f3 z/used-zir h/timestamp \
    b/used/builtin.zig p/used.tar.gz native-driver-core/h/$m1 native-driver-core/o/$f1/test \
    native-driver-core/zig-pkg/used/build.zig tools
expect_absent h/$m4 o/$f4 o/orphan z/stale-zir h/$m5 h/$m6 h/$m8 o/$f8 b/stale p/stale.tar.gz \
    native-driver-core/zig-pkg/stale tmp/.tmp-leftover source-examples/h/$m2 source-examples/o/$f2
expect_report 'Compiler cache root: 19 units; 5 manifest-output pairs; 2 manifests without output dropped; 0 build runners kept; pruned 10 units'
expect_report 'Compiler cache native-driver-core/: 4 units; 1 manifest-output pairs; 0 manifests without output dropped; 0 build runners kept; pruned 1 units'

begin written
track
use h/$m1 o/$f1/test
write_manifest $m7
compile o/$f7/test
rewrite_unread z/stale-zir
run admit
expect_saved true
expect_present h/$m1 o/$f1/test h/$m7 o/$f7/test z/stale-zir
expect_absent h/$m2 o/$f2 z/used-zir b/used p/used.tar.gz

begin failed-restore
track failure
expect_report 'Compiler cache restored (failure): 0 bytes'
expect_absent h/$m1 o/$f1 b/used p/used.tar.gz native-driver-core
write_manifest $m1
compile o/$f1/test
compile b/fresh/builtin.zig
compile p/fresh.tar.gz
run admit
expect_saved true
expect_present h/$m1 o/$f1/test b/fresh/builtin.zig p/fresh.tar.gz
expect_report 'Compiler cache root: 4 units; 1 manifest-output pairs; 0 manifests without output dropped; 0 build runners kept; pruned 0 units'

for damage in truncated missing unrecorded; do
    begin "partial-$damage"
    case $damage in
        truncated) printf 'x' > .zig-cache/o/$f1/test ;;
        missing) rm -- .zig-cache/z/used-zir ;;
        unrecorded) rm -- .zig-cache/kosmos-cache-record ;;
    esac
    track
    expect_report '::warning::Compiler cache: the restored tree differs from its record'
    expect_report 'Compiler cache restored (success): '
    expect_absent h/$m1 o/$f1 z/used-zir kosmos-cache-record
done

begin round-trip
track
use h/$m1 o/$f1/test
run admit
expect_saved true
track
expect_present h/$m1 o/$f1/test tools
expect_absent kosmos-cache-record
if grep -Fq 'differs from its record' "$workspace/report"; then
    fail "a complete tree was discarded"
fi

begin broken
rm -rf .zig-cache/o/$f2
record_tree
track
use h/$m1 o/$f1/test h/$m2
run admit
expect_saved true
expect_absent h/$m2 o/$f2
expect_present h/$m1 o/$f1/test
expect_report '3 manifests without output dropped'

begin untracked
track
printf 'off\n' > "$KOSMOS_CACHE_STATE/tracking"
run admit
expect_saved false
expect_present h/$m4 o/$f4/test b/stale p/stale.tar.gz
expect_report '::warning::Compiler cache: reads leave no access time here'

begin degenerate
track
run admit
expect_saved false
expect_present h/$m1 o/$f1/test b/stale
expect_report '::warning::Compiler cache: the job used no compiled output; save skipped'

begin ceiling
track
use h/$m1 o/$f1/test
KOSMOS_CACHE_BYTES_MAX=10 run admit
expect_saved false
expect_absent kosmos-cache-record
expect_report '-byte ceiling; save skipped'

begin tool-failure
mkdir -p -- "$scratch/broken-zig"
printf '#!/bin/sh\nexit 1\n' > "$scratch/broken-zig/zig"
chmod +x -- "$scratch/broken-zig/zig"
PATH="$scratch/broken-zig:$PATH" track || fail "track failed with a broken pairing tool"
expect_report '::warning::Compiler cache: the pairing tool failed to build'
use h/$m1 o/$f1/test
PATH="$scratch/broken-zig:$PATH" run admit || fail "admit failed with a broken pairing tool"
expect_saved false
expect_report '::warning::Compiler cache: the pairing tool failed; save skipped'
expect_present h/$m4 o/$f4/test

begin stage
track
use h/$m1 o/$f1/test b/used/builtin.zig
write_manifest $m7
compile o/$f7/test
run stage
expect_saved true
expect_recorded
expect_present h/$m1 o/$f1/test h/$m7 o/$f7/test b/used/builtin.zig tools
expect_absent h/$m2 o/$f2 source-examples/h/$m2 source-examples/o/$f2 z/used-zir p/used.tar.gz
: > "$GITHUB_OUTPUT"
use h/$m1 o/$f1/test h/$m7 o/$f7/test
run unstage
expect_absent kosmos-cache-record
expect_present h/$m2 o/$f2/test source-examples/h/$m2 source-examples/o/$f2/test z/used-zir \
    p/used.tar.gz h/$m4 o/$f4/test
use source-examples/h/$m2 source-examples/o/$f2/test
compile z/checked-zir
run admit
expect_saved true
expect_recorded
expect_present h/$m1 o/$f1/test h/$m7 o/$f7/test b/used/builtin.zig source-examples/h/$m2 \
    source-examples/o/$f2/test z/checked-zir tools
expect_absent h/$m2 o/$f2 h/$m4 o/$f4 z/used-zir p/used.tar.gz

scenario=build-runner
find "$scratch/tools-cache/.zig-cache/tools/h" "$ZIG_GLOBAL_CACHE_DIR/h" -type f ! -name timestamp \
    -size +0c > "$scratch/real-manifests"
runner_manifest=
while IFS= read -r manifest; do
    if grep -aqE 'b/[0-9a-f]{32}/builtin\.zig' "$manifest"; then
        runner_manifest=$manifest
        break
    fi
done < "$scratch/real-manifests"
if [[ -z "$runner_manifest" ]]; then
    fail "no real manifest records a builtin module"
else
    begin build-runner
    runner_name=$(basename "$runner_manifest")
    cp -- "$runner_manifest" .zig-cache/h/"$runner_name"
    cp -- "$runner_manifest" .zig-cache/native-driver-core/h/"$runner_name"
    pairing=$(printf 'h/%s\n' "$runner_name" |
        zig run -fstrip --cache-dir "$scratch/tools-cache/.zig-cache/tools" "$tools/zig-cache-pairs.zig" -- \
            "$(dirname "$(dirname "$runner_manifest")")")
    runner_output=$(cut -f2 <<< "$pairing")
    mapfile -t runner_inputs < <(tr '\t' '\n' <<< "$pairing" | tail -n +3)
    if [[ "$runner_output" != o/* || ${#runner_inputs[@]} -eq 0 ]]; then
        fail "the real manifest names no output directory or inputs: $pairing"
    fi
    restored_file ".zig-cache/$runner_output/maker"
    restored_file ".zig-cache/native-driver-core/$runner_output/test"
    for input in "${runner_inputs[@]}"; do
        restored_file ".zig-cache/$input"
    done
    record_tree
    track
    use h/$m1 o/$f1/test
    run admit
    expect_saved true
    expect_present "h/$runner_name" "$runner_output/maker" "${runner_inputs[@]}" h/$m1 o/$f1/test
    expect_absent b/stale "native-driver-core/h/$runner_name" "native-driver-core/$runner_output"
    expect_report '1 build runners kept'
fi

scenario=unreadable-manifest
mkdir -p -- "$scratch/unreadable/h/$m1"
if printf 'h/%s\n' "$m1" | zig run -fstrip --cache-dir "$scratch/tools-cache/.zig-cache/tools" \
    "$tools/zig-cache-pairs.zig" -- "$scratch/unreadable" > "$scratch/unreadable.tsv" 2> /dev/null; then
    fail "the pairing tool paired a manifest it could not read: $(< "$scratch/unreadable.tsv")"
fi
begin unreadable-manifest
track
use h/$m1 o/$f1/test
chmod 000 .zig-cache/h/$m2
if cat -- .zig-cache/h/$m2 > /dev/null 2>&1; then
    printf 'This user reads a file without read permission; cannot test a manifest read failure.\n' >&2
    exit 1
fi
run admit || fail "admit failed on a manifest read failure"
expect_saved false
expect_report '::warning::Compiler cache: the pairing tool failed; save skipped'
expect_present h/$m4 o/$f4/test
chmod 644 .zig-cache/h/$m2

scenario=host-cpu
flags=(fpu cx8 cmov mmx fxsr sse sse2 lm pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm avx avx2
    bmi1 bmi2 f16c fma abm movbe xsave sha_ni)
host_cpu() {
    printf 'processor\t: 0\nmodel name\t: test\nflags\t\t: %s\n\n' "$*" | bash "$script" host-cpu
}
[[ "$(host_cpu "${flags[@]}")" == x86_64_v3+sha ]] || fail "a runner with every flag is not x86_64_v3+sha"
for flag in pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave sha_ni; do
    without=()
    for present in "${flags[@]}"; do
        [[ "$present" == "$flag" ]] || without+=("$present")
    done
    [[ "$(host_cpu "${without[@]}")" == baseline ]] || fail "a runner without $flag is not baseline"
done
[[ "$(host_cpu)" == baseline ]] || fail "a runner without flags is not baseline"

scenario=workflow
awk '
    /^  [a-z-]+:$/ { job = $1 }
    job == "qualify:" && /^      - / { steps++ }
    job == "qualify:" && /^      - name: / { sub(/^      - name: /, ""); name[steps] = $0 }
    job == "qualify:" && /^        name: / { sub(/^        name: /, ""); name[steps] = $0 }
    job == "qualify:" && /^        if: / { condition[steps] = $0 }
    END { for (i = 1; i <= steps; i++) printf "%d\t%s\t%s\n", i, name[i], condition[i] }
' "$workflow" > "$scratch/steps.tsv"
step() {
    awk -F '\t' -v pattern="$1" '$2 ~ pattern { print $1 }' "$scratch/steps.tsv"
}
steps=$(wc -l < "$scratch/steps.tsv")
track_step=$(step '^Verify the restored compiler cache')
stage_step=$(step '^Set aside what the compilation')
compiled_step=$(step '^Save the compiled lane')
unstage_step=$(step '^Return what the compilation')
admit_step=$(step '^Prune the compiler cache to what the job used')
checked_step=$(step '^Save the checked lane')
last_compile=$(awk -F '\t' '$2 ~ /^Compile/ { last = $1 } END { print last }' "$scratch/steps.tsv")
first_compile=$(awk -F '\t' '$2 ~ /^Compile/ { print $1; exit }' "$scratch/steps.tsv")
(( track_step < first_compile && stage_step == last_compile + 1 && compiled_step == stage_step + 1 &&
    unstage_step == compiled_step + 1 )) ||
    fail "the compile save does not directly follow the last compilation"
(( admit_step == steps - 1 && checked_step == steps )) || fail "the job's save is not its last step"
for index in "$stage_step" "$compiled_step" "$unstage_step" "$admit_step" "$checked_step"; do
    if awk -F '\t' -v i="$index" '$1 == i && $3 ~ /always\(\)|cancelled\(\)|failure\(\)|success\(\)/' \
        "$scratch/steps.tsv" | grep -q .; then
        fail "step $index runs after a failed step"
    fi
done
grep -E '^ +(key: )?\$\{\{ env\.KOSMOS_CACHE_PREFIX \}\}/' "$workflow" > "$scratch/keys.txt"
grep -cE '^ +key: ' "$workflow" > "$scratch/key-count"
(( $(wc -l < "$scratch/keys.txt") == 8 && $(< "$scratch/key-count") == 3 )) ||
    fail "not every compiler cache key starts with KOSMOS_CACHE_PREFIX"
(( $(grep -Fc -- "-\${{ github.run_number }}-\${{ github.run_attempt }}-" "$scratch/keys.txt") == 3 )) ||
    fail "a saved key lacks the run number and attempt"
if ! grep -Eq 'KOSMOS_CACHE_PREFIX=kosmos-native-v6-%s-%s-0\.17\.1-%s-%s' "$workflow" ||
    ! grep -Fq "\"\$RUNNER_OS\" \"\$RUNNER_ARCH\" \"\$KOSMOS_HOST_TARGET\" \"\$cpu\"" "$workflow"; then
    fail "the key prefix does not name the host target and the chosen CPU"
fi

scenario=retention
awk '
    /^          SUPERSEDED: \|$/ { active = 1; next }
    active && /^            / { sub(/^            /, ""); print; next }
    active { exit }
' "$workflow" > "$scratch/superseded.jq"
v3=kosmos-native-v6-Linux-X64-0.17.1-x86_64-linux.5.10...7.2-gnu.2.31-x86_64_v3+sha
v1=kosmos-native-v6-Linux-X64-0.17.1-x86_64-linux.5.10...7.2-gnu.2.31-baseline
cat > "$scratch/caches.json" << EOF
[
  {"id": 1, "size_in_bytes": 1, "created_at": "2026-11-27T10:00:00Z", "key": "$v3/sessions/aa-100-1-checked"},
  {"id": 2, "size_in_bytes": 1, "created_at": "2026-11-27T11:00:00Z", "key": "$v1/sessions/aa-99-1-checked"},
  {"id": 3, "size_in_bytes": 1, "created_at": "2026-11-27T12:00:00Z", "key": "$v3/sessions/aa-99-1-checked"},
  {"id": 4, "size_in_bytes": 1, "created_at": "2026-11-27T09:59:00Z", "key": "$v3/sessions/aa-100-1-compiled"},
  {"id": 5, "size_in_bytes": 1, "created_at": "2026-11-27T08:00:00Z", "key": "$v3/native/bb-98-2-compiled"},
  {"id": 6, "size_in_bytes": 1, "created_at": "2026-11-27T13:00:00Z", "key": "$v3/native/aa-98-1-checked"},
  {"id": 7, "size_in_bytes": 1, "created_at": "2026-11-27T14:00:00Z", "key": "kosmos-native-v5-Linux-X64/sessions/aa-1-1"},
  {"id": 8, "size_in_bytes": 1, "created_at": "2026-11-27T15:00:00Z", "key": "setup-zig-0.17.1"}
]
EOF
superseded() {
    jq -r '.[]' "$scratch/caches.json" | jq -rs --arg state "$1" -f "$scratch/superseded.jq" | cut -f1 |
        LC_ALL=C sort | tr '\n' ' '
}
[[ "$(superseded open)" == "3 4 6 7 " ]] || fail "open retention deleted: $(superseded open)"
[[ "$(superseded closed)" == "1 2 3 4 5 6 7 8 " ]] || fail "closed retention deleted: $(superseded closed)"

scenario=zig-pairs
for directory in "$scratch/tools-cache/.zig-cache/tools" "$ZIG_GLOBAL_CACHE_DIR"; do
    find "$directory/h" -type f ! -name timestamp -size +0c -printf 'h/%P\n' > "$scratch/finalized.txt"
    zig run -fstrip --cache-dir "$scratch/tools-cache/.zig-cache/tools" \
        "$tools/zig-cache-pairs.zig" -- "$directory" < "$scratch/finalized.txt" > "$scratch/zig-pairs.tsv"
    finalized=$(wc -l < "$scratch/finalized.txt")
    paired=$(awk -F '\t' '$2 ~ /^(o|c)\/[0-9a-f]+$/' "$scratch/zig-pairs.tsv" | wc -l)
    (( finalized > 0 && paired == finalized )) ||
        fail "$directory: $paired of $finalized finalized Zig manifests name an existing output"
    while IFS= read -r input; do
        [[ -e "$directory/$input" || -e "$ZIG_GLOBAL_CACHE_DIR/$input" ]] ||
            fail "$directory: recorded cache input $input does not exist"
    done < <(cut -f3- "$scratch/zig-pairs.tsv" | tr '\t' '\n' | sed '/^$/d')
done

if (( failures > 0 )); then
    printf '%d compiler cache checks failed.\n' "$failures" >&2
    exit 1
fi
printf 'Compiler cache admission: all scenarios passed.\n'
