#!/usr/bin/env bash
set -euo pipefail

tools=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$tools/zig-cache.sh
workflow=$tools/../.github/workflows/runtime-bundle.yml
scratch=$(mktemp -d "${TMPDIR:-/tmp}/zig-cache-test.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
export RUNNER_TEMP=$scratch
unset KOSMOS_HOST_TARGET KOSMOS_HOST_CPU KOSMOS_CACHE_BYTES_MAX KOSMOS_CACHE_STEP_SECONDS_MAX
REAL_FIND=$(command -v find)
REAL_MV=$(command -v mv)
REAL_RM=$(command -v rm)
REAL_ZIG=$(command -v zig)
export REAL_FIND REAL_MV REAL_RM REAL_ZIG
tool_cache=$scratch/zig-cache-pairs
pairs_tool=$tool_cache/zig-cache-pairs
real_cache=$scratch/real-cache
failures=0

m1=00000000000000000000000000000001 f1=eaae50b21867a4fc20733d2d7251e2b6
m2=00000000000000000000000000000002 f2=a99b3baeeff2e8f171303f036b0d3707
m3=00000000000000000000000000000003 f3=a625e6377ce995bd1579a3550ec1b100
m4=00000000000000000000000000000004 f4=46db8c643cc4fb63b0585ab7edab3d52
m5=00000000000000000000000000000005
m6=00000000000000000000000000000006
m7=00000000000000000000000000000007 f7=efdb98b0b2f2e4035e7d72d2daa34619
m8=00000000000000000000000000000008 f8=f8e51811854fbb1a0ea0cf0382772caf
m9=00000000000000000000000000000009 f9=1dbb5dec00b322ff9547f39d5401c828
m10=0000000000000000000000000000000a f10=8e71e2b9cd08bfa51c6bd7b6f3139158
m11=0000000000000000000000000000000b f11=de67a6b69f662fbad43221270c3c5a5d
m12=0000000000000000000000000000000c f12=5d2d57063a704c006bb139b35c246609
m13=0000000000000000000000000000000d f13=ac5ccc6c534c25a14bf4bbe04b12bc3c
m14=0000000000000000000000000000000e f14=a3cfd7ea9f35d9c11a48dcaad2b6a3f3

fail() {
    printf 'FAIL %s: %s\n' "$scenario" "$1" >&2
    failures=$((failures + 1))
}

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

restored_manifest_input() {
    mkdir -p -- "$(dirname "$1")"
    {
        head -c 40 /dev/zero
        printf '%b%s\0\0' "$2" "$3"
    } > "$1"
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
    KOSMOS_JOB_STARTED=$(date +%s)
    export KOSMOS_JOB_STARTED
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
    record_tree
}

build_tool() {
    ZIG_GLOBAL_CACHE_DIR=$workspace/.zig-cache bash "$script" tool > "$workspace/report"
}

track() {
    bash "$script" track "${1:-success}" > "$workspace/report"
}

expect_kept() {
    if grep -Fq 'differs from its record' "$workspace/report"; then
        fail "a complete tree was discarded"
    fi
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

failing() {
    mkdir -p -- "$workspace/failing"
    {
        printf '#!/usr/bin/env bash\n'
        cat
    } > "$workspace/failing/$1"
    chmod +x -- "$workspace/failing/$1"
    failing_path=$workspace/failing:$PATH
}

aside_moves() {
    rm -f -- "$workspace/moves"
    failing mv << EOF
if [[ "\$*" == */aside/* ]]; then
    printf '%s\n' "\${@: -2:1}" >> '$workspace/moves'
    if (( \$(wc -l < '$workspace/moves') >= $1 )); then
        exit 1
    fi
fi
exec "\$REAL_MV" "\$@"
EOF
}

expect_manifests() {
    local order pattern='^m+u+$'
    order=$(awk '{ printf "%s", ($0 ~ /\/h\/[0-9a-f]+$/) ? "m" : "u" }' "$workspace/moves")
    if [[ "$1" == last ]]; then
        pattern='^u+m+$'
    fi
    [[ "$order" =~ $pattern ]] || fail "manifests do not move $1: $order"
}

expect_paired() {
    local pair
    for pair in "h/$m2 o/$f2" "h/$m3 c/$f3" "h/$m4 o/$f4" "source-examples/h/$m2 source-examples/o/$f2"; do
        if [[ -e ".zig-cache/${pair% *}" && ! -e ".zig-cache/${pair#* }" ]]; then
            fail "${pair% *} is present without ${pair#* }"
        fi
    done
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

expect_history() {
    if ! cmp -s .zig-cache/kosmos-build-runners <(printf '%s\n' "$@"); then
        fail "build runner history: $(tr '\n' '|' < .zig-cache/kosmos-build-runners 2> /dev/null)"
    fi
}

begin cold-tool
failing zig << 'EOF'
sleep 2
exec "$REAL_ZIG" "$@"
EOF
PATH=$failing_path build_tool || fail "a slow cold build of the pairing tool failed"
expect_report 'Compiler cache: built the pairing tool'
[[ -x "$pairs_tool" ]] || fail "the pairing tool was not built"
KOSMOS_CACHE_STEP_SECONDS_MAX=1 track || fail "track exceeded its limit after a slow cold build of the pairing tool"
expect_report 'Compiler cache restored (success)'
expect_kept
use h/$m1 o/$f1/test
run stage
expect_saved true
: > "$GITHUB_OUTPUT"
run unstage
run admit
expect_saved true
expect_present h/$m1 o/$f1/test

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
    native-driver-core/zig-pkg/used/build.zig
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
expect_present h/$m1 o/$f1/test
expect_absent kosmos-cache-record
expect_kept

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

for failure in failed stopped; do
    begin "tool-$failure"
    if [[ "$failure" == failed ]]; then
        failing zig <<< 'exit 1'
    else
        failing zig <<< 'sleep 5'
    fi
    [[ -x "$pairs_tool" ]] || fail "no pairing tool before a $failure build"
    started=$(date +%s)
    if PATH=$failing_path KOSMOS_CACHE_STEP_SECONDS_MAX=1 build_tool; then
        fail "a $failure build of the pairing tool succeeded"
    fi
    (( $(date +%s) - started <= 3 )) || fail "a stopped tool build took $(( $(date +%s) - started )) s for a 1 s limit"
    if [[ "$failure" == failed ]]; then
        expect_report '::warning::Compiler cache: tool failed with status 1; this job saves no further compiler cache'
    else
        expect_report '::warning::Compiler cache: tool exceeded its 1 s limit and was stopped; this job saves no further compiler cache'
    fi
    [[ ! -e "$pairs_tool" ]] || fail "a $failure build left a pairing tool"
    track || fail "track failed after a $failure build of the pairing tool"
    expect_kept
    use h/$m1 o/$f1/test
    run stage || fail "stage failed without the pairing tool"
    expect_saved false
    expect_report '::warning::Compiler cache: the pairing tool failed; save skipped'
    run unstage
    run admit || fail "admit failed without the pairing tool"
    expect_saved false
    expect_report '::warning::Compiler cache: the pairing tool failed; save skipped'
    expect_present h/$m4 o/$f4/test
    begin "tool-$failure-next-job"
    build_tool || fail "the job after a $failure build of the pairing tool could not build it"
    track
    expect_kept
    use h/$m1 o/$f1/test
    run admit
    expect_saved true
done

begin stage
track
use h/$m1 o/$f1/test b/used/builtin.zig
write_manifest $m7
compile o/$f7/test
run stage
expect_saved true
expect_recorded
expect_present h/$m1 o/$f1/test h/$m7 o/$f7/test b/used/builtin.zig
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
    source-examples/o/$f2/test z/checked-zir
expect_absent h/$m2 o/$f2 h/$m4 o/$f4 z/used-zir p/used.tar.gz

scenario=build-runner
mkdir -p -- "$real_cache"
(cd "$real_cache" && zig run -fstrip --cache-dir local --global-cache-dir "$tool_cache/global" \
    "$tools/zig-cache-pairs.zig" -- local < /dev/null)
find "$real_cache/local/h" "$tool_cache/global/h" -type f ! -name timestamp \
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
    pairing=$(printf 'h/%s\n' "$runner_name" | "$pairs_tool" "$(dirname "$(dirname "$runner_manifest")")")
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
    for runner in "$m9 $f9" "$m10 $f10" "$m11 $f11" "$m12 $f12"; do
        restored_manifest ".zig-cache/h/${runner% *}"
        restored_file ".zig-cache/o/${runner#* }/maker"
    done
    printf '%s\n' "o/$f10" "$runner_output" o/gone '' '' "o/$f11" > .zig-cache/kosmos-build-runners
    record_tree
    track
    expect_absent kosmos-build-runners
    use h/$m1 o/$f1/test h/$m9 o/$f9/maker
    run stage
    expect_saved true
    expect_recorded
    expect_history "o/$f9" "o/$f10" "$runner_output" '' '' ''
    expect_present "h/$runner_name" "$runner_output/maker" "${runner_inputs[@]}" h/$m9 o/$f9/maker \
        h/$m10 o/$f10/maker
    expect_absent h/$m11 o/$f11 h/$m12 o/$f12 "native-driver-core/h/$runner_name" \
        "native-driver-core/$runner_output"
    expect_report '3 build runners kept'
    : > "$GITHUB_OUTPUT"
    run unstage
    expect_absent kosmos-build-runners
    run admit
    expect_saved true
    expect_recorded
    expect_history "o/$f9" "o/$f10" "$runner_output" '' '' ''
    expect_present "h/$runner_name" "$runner_output/maker" "${runner_inputs[@]}" h/$m1 o/$f1/test \
        h/$m9 o/$f9/maker h/$m10 o/$f10/maker
    expect_absent b/stale h/$m11 o/$f11 h/$m12 o/$f12 "native-driver-core/h/$runner_name" \
        "native-driver-core/$runner_output"
    expect_report '3 build runners kept'
    track
    use h/$m1 o/$f1/test
    run admit
    expect_saved true
    expect_history '' "o/$f9" "o/$f10" "$runner_output" '' ''
fi

scenario=unreadable-manifest
mkdir -p -- "$scratch/unreadable/h/$m1"
if printf 'h/%s\n' "$m1" | "$pairs_tool" "$scratch/unreadable" > "$scratch/unreadable.tsv" 2> /dev/null; then
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

begin transitive
restored_manifest_input .zig-cache/h/$m13 '\x08' "o/$f14/generated"
restored_file .zig-cache/o/$f13/test
restored_manifest_input .zig-cache/h/$m14 '\x0c' b/transitive/builtin.zig
restored_file .zig-cache/o/$f14/generated
restored_file .zig-cache/b/transitive/builtin.zig
record_tree
track
use h/$m13 o/$f13/test
run admit
expect_saved true
expect_recorded
expect_present h/$m13 o/$f13/test o/$f14/generated h/$m14 b/transitive/builtin.zig
expect_absent h/$m4 o/$f4 b/stale

begin track-failure
failing touch <<< 'exit 1'
if PATH=$failing_path track; then
    fail "track succeeded with a failing touch"
fi
expect_report '::warning::Compiler cache: track failed'
expect_present h/$m1 o/$f1/test h/$m4 o/$f4/test b/stale
use h/$m1 o/$f1/test
run stage
expect_saved false
run unstage
run admit
expect_saved false
expect_report 'untracked, or an earlier compiler cache step failed; save skipped'
expect_present h/$m4 o/$f4/test b/stale

begin track-discard
printf 'x' > .zig-cache/o/$f1/test
failing rm << 'EOF'
if [[ "$*" == *.zig-cache* ]]; then
    exit 1
fi
exec "$REAL_RM" "$@"
EOF
if PATH=$failing_path track; then
    fail "track succeeded with a failing rm"
fi
expect_report '::warning::Compiler cache: the restored tree differs from its record'
[[ ! -e .zig-cache ]] || fail "a tree that differs from its record stayed in place"

begin classify-failure
track
use h/$m1 o/$f1/test
failing find << EOF
if [[ "\$*" == *%A@* ]]; then
    "\$REAL_FIND" "\$@" | grep -v 'h/$m4'
    exit 1
fi
exec "\$REAL_FIND" "\$@"
EOF
if PATH=$failing_path run admit; then
    fail "admit succeeded with a failing listing"
fi
expect_saved false
expect_report '::warning::Compiler cache: admit failed'
expect_present h/$m4 o/$f4/test b/stale

begin move-order
track
use h/$m1 o/$f1/test
aside_moves 1000
PATH=$failing_path run stage
expect_saved true
expect_manifests first
aside_moves 1000
PATH=$failing_path run unstage
expect_manifests last

begin stage-failure
track
use h/$m1 o/$f1/test
aside_moves 2
if PATH=$failing_path run stage; then
    fail "stage succeeded with a failing move"
fi
expect_saved false
expect_paired
run unstage
expect_present h/$m2 o/$f2/test h/$m3 c/$f3 h/$m4 o/$f4/test h/$m5 h/$m6 h/$m8 o/$f8 o/orphan \
    z/used-zir z/stale-zir b/used b/stale p/used.tar.gz p/stale.tar.gz \
    native-driver-core/zig-pkg/stale source-examples/h/$m2 source-examples/o/$f2/test
run admit
expect_saved false
expect_report 'untracked, or an earlier compiler cache step failed; save skipped'

begin unstage-failure
track
use h/$m1 o/$f1/test
run stage
expect_saved true
: > "$GITHUB_OUTPUT"
aside_moves 2
if PATH=$failing_path run unstage; then
    fail "unstage succeeded with a failing move"
fi
expect_paired
run admit
expect_saved false
expect_report 'untracked, or an earlier compiler cache step failed; save skipped'

begin late
track
use h/$m1 o/$f1/test
KOSMOS_JOB_STARTED=$(( $(date +%s) - 451 )) run admit
expect_saved false
expect_report "of the job's 600 s remain, fewer than the 150 s"
expect_present h/$m4 o/$f4/test b/stale
KOSMOS_JOB_STARTED='' run admit
expect_saved false
expect_report '::warning::Compiler cache: the job start is unknown'
KOSMOS_JOB_STARTED=$(( $(date +%s) - 440 )) run admit
expect_saved true
expect_absent h/$m4 o/$f4 b/stale

begin due
run due || fail "due exited $?"
[[ "$(tail -n 1 "$GITHUB_OUTPUT")" == due=true ]] || fail "an on-time job does not restore"
KOSMOS_JOB_STARTED=$(( $(date +%s) - 451 )) run due || fail "a late due exited $?"
[[ "$(tail -n 1 "$GITHUB_OUTPUT")" == due=false ]] || fail "a late job restores"
expect_report "of the job's 600 s remain, fewer than the 150 s a cache step needs to begin; restore skipped"
KOSMOS_JOB_STARTED='' run due || fail "due with an unknown start exited $?"
[[ "$(tail -n 1 "$GITHUB_OUTPUT")" == due=true ]] || fail "an unknown start skips the restore"
expect_report '::warning::Compiler cache: the job start is unknown, so the cache steps before the checks run'

begin late-tool
RUNNER_TEMP=$workspace/runner KOSMOS_JOB_STARTED=$(( $(date +%s) - 451 )) build_tool ||
    fail "a late build of the pairing tool failed"
expect_report "fewer than the 150 s a cache step needs to begin; the pairing tool is not built"
[[ ! -e "$workspace/runner/zig-cache-pairs" ]] || fail "a late job built the pairing tool"

begin late-track
KOSMOS_JOB_STARTED=$(( $(date +%s) - 451 )) track
expect_report "fewer than the 150 s a cache step needs to begin; the restored tree is set aside"
[[ ! -e .zig-cache && -e .zig-cache.restored/h/$m1 ]] || fail "a late track left the unverified tree in place"
compile o/$f1/test
run stage
expect_saved false
expect_report 'untracked, or an earlier compiler cache step failed; save skipped'

begin late-stage
track
use h/$m1 o/$f1/test
KOSMOS_JOB_STARTED=$(( $(date +%s) - 451 )) run stage
expect_saved false
expect_report "fewer than the 150 s a cache step needs to begin; save skipped"
expect_present h/$m2 o/$f2/test h/$m4 o/$f4/test b/stale p/stale.tar.gz
[[ ! -e "$KOSMOS_CACHE_STATE/aside" ]] || fail "a late stage set units aside"
: > "$GITHUB_OUTPUT"
run unstage
run admit
expect_saved true
expect_present h/$m1 o/$f1/test
expect_absent h/$m4 o/$f4 b/stale

printf "trap '' TERM\n" > "$scratch/ignore-term"
for signal in term kill; do
    begin "track-timeout-$signal"
    failing touch <<< 'sleep 5'
    started=$(date +%s)
    if [[ "$signal" == term ]]; then
        PATH=$failing_path KOSMOS_CACHE_STEP_SECONDS_MAX=1 track && fail "track succeeded past its limit"
    else
        BASH_ENV=$scratch/ignore-term PATH=$failing_path KOSMOS_CACHE_STEP_SECONDS_MAX=1 track &&
            fail "track ignoring SIGTERM succeeded past its limit"
    fi
    (( $(date +%s) - started <= 3 )) || fail "a stopped track took $(( $(date +%s) - started )) s for a 1 s limit"
    expect_report '::warning::Compiler cache: track exceeded its 1 s limit and was stopped; this job saves no further compiler cache'
    [[ ! -e .zig-cache.restored ]] || [[ ! -e .zig-cache ]] || fail "a stopped track left two trees"
    run stage
    expect_saved false
    run unstage
    run admit
    expect_saved false
    expect_report 'untracked, or an earlier compiler cache step failed; save skipped'
done

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
    job == "qualify:" && /^        continue-on-error: / { tolerated[steps] = $2 }
    job == "qualify:" && /^        timeout-minutes: / { minutes[steps] = $2 }
    job == "qualify:" && /tools\/zig-cache\.sh (due|tool|track|stage|unstage|admit)|uses: actions\/cache\// { cache[steps] = 1 }
    END {
        for (i = 1; i <= steps; i++) {
            printf "%d\t%s\t%s\t%s\t%s\t%d\n", i, name[i], condition[i], tolerated[i], minutes[i], cache[i]
        }
    }
' "$workflow" > "$scratch/steps.tsv"
awk -F '\t' '($6 || $2 ~ /^Record native compiler/) && !($4 == "true" && $5 == 1) { print $2 }' \
    "$scratch/steps.tsv" > "$scratch/intolerant.txt"
(( $(awk -F '\t' '$6' "$scratch/steps.tsv" | wc -l) == 9 )) || fail "the qualification job does not have nine cache steps"
[[ ! -s "$scratch/intolerant.txt" ]] ||
    fail "a cache step can fail the lane or outlast a minute: $(tr '\n' ';' < "$scratch/intolerant.txt")"
job_minutes=$(awk '/^  qualify:$/ { active = 1 } active && /^    timeout-minutes: / { print $2; exit }' "$workflow")
job_seconds=$(sed -n 's/^job_seconds_max=//p' "$script")
remaining=$(sed -n 's/^remaining_seconds_min=//p' "$script")
step_limit=$(sed -n 's/^step_seconds_max=.{KOSMOS_CACHE_STEP_SECONDS_MAX:-\([0-9]*\)}$/\1/p' "$script")
kill_after=$(sed -n 's/^kill_seconds=//p' "$script")
(( job_seconds == job_minutes * 60 && remaining >= 2 * 60 + 30 )) ||
    fail "the checked save's margin does not cover two one-minute steps and the job's end"
for mode in tool stage unstage admit; do
    grep -Fxq "        run: bash tools/zig-cache.sh $mode" "$workflow" || fail "$mode does not run under the tool's limit"
done
grep -Fxq "        run: bash tools/zig-cache.sh track \"\$RESTORE\"" "$workflow" ||
    fail "track does not run under the tool's limit"
grep -Fq "started=\$(timeout -k 1 10 gh api " "$workflow" || fail "reading the job start has no 10 s limit"
grep -Fxq "        if: steps.start.outputs.due == 'true'" "$workflow" || fail "the restore does not wait for the time check"
bound=$(( (10 + 1) + 2 * (60 + 10) + 4 * (step_limit + kill_after) ))
(( bound == 235 )) || fail "cache work before the checks may take $bound s, not the documented 235 s"
grep -Fq '11 + 70 + 21 + 21 + 21 + 70 + 21 = 235 s' "$tools/../docs/verification.md" ||
    fail "docs/verification.md does not state the 235 s bound"
if ! grep -Fq "grep -m 1 '^model name' /proc/cpuinfo || printf '::warning::" "$workflow" ||
    ! grep -Fq "if ! cpu=\$(bash tools/zig-cache.sh host-cpu < /proc/cpuinfo); then" "$workflow" ||
    ! grep -Fxq '            cpu=baseline' "$workflow"; then
    fail "the CPU diagnostic or choice can fail the lane"
fi
if ! grep -Fq "JOB_ID: \${{ job.check_run_id }}" "$workflow" ||
    ! grep -Fq "printf 'KOSMOS_JOB_STARTED=%s\\n'" "$workflow"; then
    fail "the job start is not read from the job's own record"
fi
step() {
    awk -F '\t' -v pattern="$1" '$2 ~ pattern { print $1 }' "$scratch/steps.tsv"
}
steps=$(wc -l < "$scratch/steps.tsv")
tool_step=$(step '^Build the compiler cache pairing tool')
track_step=$(step '^Verify the restored compiler cache')
stage_step=$(step '^Set aside what the compilation')
compiled_step=$(step '^Save the compiled lane')
unstage_step=$(step '^Return what the compilation')
admit_step=$(step '^Prune the compiler cache to what the job used')
checked_step=$(step '^Save the checked lane')
last_compile=$(awk -F '\t' '$2 ~ /^Compile/ { last = $1 } END { print last }' "$scratch/steps.tsv")
first_compile=$(awk -F '\t' '$2 ~ /^Compile/ { print $1; exit }' "$scratch/steps.tsv")
(( tool_step + 1 == track_step )) || fail "the pairing tool is not built in its own step directly before track"
(( track_step < first_compile && stage_step == last_compile + 1 && compiled_step == stage_step + 1 &&
    unstage_step == compiled_step + 1 )) ||
    fail "the compile save does not directly follow the last compilation"
(( admit_step == steps - 1 && checked_step == steps )) || fail "the job's save is not its last step"
for index in "$tool_step" "$stage_step" "$compiled_step" "$unstage_step" "$admit_step" "$checked_step"; do
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
awk '
    /^  [a-z-]+:$/ { job = $1 }
    job == "qualify:" && /^      - / { step++ }
    job == "qualify:" {
        builds[step] += gsub(/zig build( |$)/, "&")
        targets[step] += gsub(/-Dtarget="\$KOSMOS_HOST_TARGET" -Dcpu="\$KOSMOS_HOST_CPU"/, "&")
        pinned[step] += gsub(/-Dhost-target="\$KOSMOS_HOST_TARGET" -Dhost-cpu="\$KOSMOS_HOST_CPU"/, "&")
    }
    END {
        for (s in builds) {
            total += builds[s]
            if (builds[s] != pinned[s] || builds[s] != targets[s]) {
                print "step " s ": " builds[s] " builds, " targets[s] " targets, " pinned[s] " pinned"
            }
        }
        if (total < 10) print total " builds"
    }
' "$workflow" > "$scratch/unpinned.txt"
[[ ! -s "$scratch/unpinned.txt" ]] ||
    fail "a qualification build leaves the host target or CPU native: $(tr '\n' ';' < "$scratch/unpinned.txt")"
consumer=$tools/../test/native_consumer/build.zig
if ! grep -Fq '.@"host-target" = b.option(' "$consumer" || ! grep -Fq '.@"host-cpu" = b.option(' "$consumer"; then
    fail "the native consumer does not pass the host target and CPU to its Kosmos dependency"
fi
if ! grep -Fq 'const target = b.standardTargetOptions(.{});' "$tools/../build.zig"; then
    fail "-Dhost-target changes the default -Dtarget"
fi

scenario=closed
awk '
    /^          DELETED: \|$/ { active = 1; next }
    active && /^            / { sub(/^            /, ""); print; next }
    active { exit }
' "$tools/../.github/workflows/closed-pull-request-caches.yml" > "$scratch/deleted.jq"
printf '{"id": %d, "size_in_bytes": %d, "key": "k%d"}\n' 1 10 1 2 20 2 3 40 3 > "$scratch/listed.json"
printf '{"id": 2, "size_in_bytes": 20, "key": "k2"}\n{"id": 9, "size_in_bytes": 5, "key": "k9"}\n' \
    > "$scratch/remaining.json"
deleted=$(jq -nr --arg ref R --slurpfile listed "$scratch/listed.json" \
    --slurpfile remaining "$scratch/remaining.json" -f "$scratch/deleted.jq")
[[ "$deleted" == 'R: deleted 2 of 3 entries, 50 bytes' ]] || fail "the close summary counts unconfirmed deletions: $deleted"

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

scenario=retention-failure
run_block() {
    awk -v job="$2:" '
        /^  [a-z-]+:$/ { active = ($1 == job) }
        active && /^        run: \|$/ { body = 1; next }
        body && /^          / { sub(/^          /, ""); print; next }
        body { exit }
    ' "$1"
}
run_block "$workflow" cache-retention > "$scratch/retain.sh"
run_block "$tools/../.github/workflows/closed-pull-request-caches.yml" delete > "$scratch/close.sh"
mkdir -p -- "$scratch/gh-down" "$scratch/gh-stuck" "$scratch/retain-temp"
cat > "$scratch/gh-down/gh" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
exit 1
EOF
cat > "$scratch/gh-stuck/gh" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GH_LOG"
case "\$*" in
    *pulls/*) printf 'open\n' ;;
    *DELETE*) ;;
    *) printf '{"id": 5, "size_in_bytes": 1, "key": "$v3/native/bb-98-2-compiled"}\n{"id": 6, "size_in_bytes": 1, "key": "$v3/native/aa-98-1-checked"}\n' ;;
esac
EOF
printf '#!/usr/bin/env bash\n' > "$scratch/gh-stuck/sleep"
chmod +x -- "$scratch/gh-down/gh" "$scratch/gh-stuck/gh" "$scratch/gh-stuck/sleep"
retain() {
    : > "$scratch/gh.log"
    env PATH="$scratch/$1:$PATH" GH_LOG="$scratch/gh.log" GH_REPO=o/r CACHE_REF=refs/pull/93/merge \
        PULL_REQUEST="$2" SUPERSEDED="$(< "$scratch/superseded.jq")" DELETED="$(< "$scratch/deleted.jq")" \
        RUNNER_TEMP="$scratch/retain-temp" GITHUB_STEP_SUMMARY="$scratch/summary" \
        bash -e "$scratch/$3" > "$scratch/retain.out" 2>&1 || fail "$3 with $1 and pull request '$2' exited $?"
}
expect_retained() {
    grep -Fq -- "$1" "$scratch/retain.out" || fail "$2 lacks: $1 ($(tr '\n' '|' < "$scratch/retain.out"))"
}
retain gh-down 93 retain.sh
expect_retained '::warning::Compiler cache retention stopped where ' 'retention with the API down'
retain gh-down '' retain.sh
expect_retained '::warning::Compiler cache retention stopped where ' 'retention on main with the API down'
! grep -q DELETE "$scratch/gh.log" || fail "retention deleted after a failed listing"
retain gh-stuck 93 retain.sh
expect_retained '::warning::A deleted cache is still listed after 30 seconds' 'retention with a stuck deletion'
[[ "$(grep DELETE "$scratch/gh.log")" == 'api -X DELETE repos/o/r/actions/caches/6 --silent' ]] ||
    fail "retention deleted other than the superseded entry: $(grep DELETE "$scratch/gh.log" | tr '\n' '|')"
retain gh-down '' close.sh
expect_retained '::warning::Closed pull request cache cleanup stopped where ' 'cleanup with the API down'
retain gh-stuck '' close.sh
expect_retained '::warning::A deleted cache is still listed after 30 seconds' 'cleanup with a stuck deletion'

scenario=zig-pairs
for directory in "$real_cache/local" "$tool_cache/global"; do
    find "$directory/h" -type f ! -name timestamp -size +0c -printf 'h/%P\n' > "$scratch/finalized.txt"
    "$pairs_tool" "$directory" < "$scratch/finalized.txt" > "$scratch/zig-pairs.tsv"
    finalized=$(wc -l < "$scratch/finalized.txt")
    paired=$(awk -F '\t' '$2 ~ /^(o|c)\/[0-9a-f]+$/' "$scratch/zig-pairs.tsv" | wc -l)
    (( finalized > 0 && paired == finalized )) ||
        fail "$directory: $paired of $finalized finalized Zig manifests name an existing output"
    while IFS= read -r input; do
        [[ -e "$directory/$input" || -e "$tool_cache/global/$input" ]] ||
            fail "$directory: recorded cache input $input does not exist"
    done < <(cut -f3- "$scratch/zig-pairs.tsv" | tr '\t' '\n' | sed '/^$/d')
done

if (( failures > 0 )); then
    printf '%d compiler cache checks failed.\n' "$failures" >&2
    exit 1
fi
printf 'Compiler cache admission: all scenarios passed.\n'
