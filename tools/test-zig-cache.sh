#!/usr/bin/env bash
set -euo pipefail

tools=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$tools/zig-cache.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/zig-cache-test.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
export RUNNER_TEMP=$scratch
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

begin() {
    scenario=$1
    workspace=$scratch/$scenario
    mkdir -p -- "$workspace"
    cd "$workspace"
    export KOSMOS_CACHE_STATE=$workspace/state
    export GITHUB_OUTPUT=$workspace/output
    : > "$GITHUB_OUTPUT"
    restored_manifest .zig-cache/h/$m8
    restored_file .zig-cache/o/$f8/libcompiler_rt.a
    restored_file .zig-cache/p/package.tar.gz
    restored_file .zig-cache/tmp/.tmp-leftover/file
    local build=.zig-cache/local/build
    restored_manifest $build/h/$m1
    restored_manifest $build/h/$m2
    restored_manifest $build/h/$m3
    restored_manifest $build/h/$m4
    restored_manifest $build/h/$m5
    restored_file $build/h/$m6 ''
    restored_file $build/h/timestamp
    restored_file $build/o/$f1/test
    restored_file $build/o/$f2/test
    restored_file $build/c/$f3
    restored_file $build/o/$f4/test
    restored_file $build/o/orphan/test
    restored_file $build/z/used-zir
    restored_file $build/z/stale-zir
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

rewrite_unread() {
    compile "$1"
    touch -a -d @1 -- ".zig-cache/$1"
    touch -m -d @1000000000 -- ".zig-cache/$1"
}

admit() {
    bash "$script" admit "${1:-1000000000}" > "$workspace/report"
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
        [[ -e ".zig-cache-upload/$path" ]] || fail "missing $path"
    done
}

expect_absent() {
    local path
    for path in "$@"; do
        [[ ! -e ".zig-cache-upload/$path" ]] || fail "retained $path"
    done
}

expect_report() {
    grep -Fq -- "$1" "$workspace/report" || {
        fail "report lacks: $1"
        cat "$workspace/report" >&2
    }
}

begin pairs
bash "$script" track 600 > /dev/null
if [[ "$(< "$KOSMOS_CACHE_STATE/tracking")" != on ]]; then
    printf 'Access-time tracking is unavailable on this filesystem; cannot test pruning.\n' >&2
    exit 1
fi
use local/build/h/$m1 local/build/o/$f1/test local/build/h/$m2 local/build/c/$f3 \
    local/build/z/used-zir
admit
expect_saved true
expect_present local/build/h/$m1 local/build/o/$f1/test local/build/h/$m2 \
    local/build/o/$f2/test local/build/h/$m3 local/build/c/$f3 local/build/z/used-zir \
    local/build/h/timestamp h/$m8 o/$f8/libcompiler_rt.a p/package.tar.gz
expect_absent local/build/h/$m4 local/build/o/$f4 local/build/o/orphan \
    local/build/z/stale-zir local/build/h/$m5 local/build/h/$m6 tmp/.tmp-leftover
expect_report 'local/build/: 13 units; 4 manifest-output pairs; 2 manifests without output dropped; pruned 6 units'

begin written
bash "$script" track 600 > /dev/null
use local/build/h/$m1 local/build/o/$f1/test
printf '\0' > .zig-cache/local/build/h/$m7
compile local/build/o/$f7/test
rewrite_unread local/build/z/stale-zir
admit
expect_saved true
expect_present local/build/h/$m7 local/build/o/$f7/test local/build/z/stale-zir
expect_absent local/build/h/$m2 local/build/o/$f2 local/build/z/used-zir

begin broken
rm -rf .zig-cache/local/build/o/$f2
bash "$script" track 600 > /dev/null
use local/build/h/$m1 local/build/o/$f1/test local/build/h/$m2
admit
expect_saved true
expect_absent local/build/h/$m2 local/build/o/$f2
expect_present local/build/h/$m1 local/build/o/$f1/test
expect_report '3 manifests without output dropped'

begin untracked
bash "$script" track 600 > /dev/null
printf 'off\n' > "$KOSMOS_CACHE_STATE/tracking"
admit
expect_saved true
expect_present local/build/h/$m4 local/build/o/$f4/test local/build/o/orphan/test \
    local/build/z/stale-zir
expect_absent local/build/h/$m5 local/build/h/$m6
expect_report 'local/build/: 13 units; 4 manifest-output pairs; 2 manifests without output dropped; pruned 2 units'

begin ceiling
head -c 4194304 /dev/urandom > .zig-cache/o/$f8/libcompiler_rt.a
bash "$script" track 600 > /dev/null
use local/build/h/$m1 local/build/o/$f1/test
admit 3145728
expect_saved true
expect_present p/package.tar.gz local/build/h/$m1 local/build/o/$f1/test
expect_absent h/$m8 o/$f8
expect_report '(all caches pruned)'
admit 1
expect_saved false
expect_report '::warning::Compiler cache: even what this run used exceeds the lane maximum'

begin deadline
bash "$script" track 2 > /dev/null
printf 'false\nexit 0\n' > "$workspace/errexit.sh"
printf 'exit 3\n' > "$workspace/status.sh"
printf 'sleep 30\n' > "$workspace/slow.sh"
status=0
bash "$script" work "$workspace/errexit.sh" > "$workspace/report" || status=$?
(( status == 1 )) || fail "a failing command returned $status, not 1"
status=0
bash "$script" work "$workspace/status.sh" > "$workspace/report" || status=$?
(( status == 3 )) || fail "the step status became $status, not 3"
status=0
started=$SECONDS
bash "$script" work "$workspace/slow.sh" > "$workspace/report" || status=$?
(( status == 124 )) || fail "a step past the deadline returned $status, not 124"
(( SECONDS - started < 15 )) || fail "a step ran $((SECONDS - started)) s past a 2 s deadline"
expect_report '::error::Lane work reached its deadline'
status=0
bash "$script" work "$workspace/status.sh" > "$workspace/report" || status=$?
(( status == 124 )) || fail "a step after the deadline returned $status, not 124"

scenario=zig-pairs
for directory in "$scratch/zig-cache-pairs/local" "$scratch/zig-cache-pairs/global"; do
    find "$directory/h" -type f ! -name timestamp -size +0c -printf 'h/%P\n' > "$scratch/finalized.txt"
    zig run --cache-dir "$scratch/zig-cache-pairs/local" \
        --global-cache-dir "$scratch/zig-cache-pairs/global" \
        "$tools/zig-cache-pairs.zig" -- "$directory" < "$scratch/finalized.txt" > "$scratch/zig-pairs.tsv"
    finalized=$(wc -l < "$scratch/finalized.txt")
    paired=$(awk -F '\t' '$2 ~ /^(o|c)\/[0-9a-f]+$/' "$scratch/zig-pairs.tsv" | wc -l)
    (( finalized > 0 && paired == finalized )) ||
        fail "$directory: $paired of $finalized finalized Zig manifests name an existing output"
done

if (( failures > 0 )); then
    printf '%d compiler cache admission checks failed.\n' "$failures" >&2
    exit 1
fi
printf 'Compiler cache admission: all scenarios passed.\n'
