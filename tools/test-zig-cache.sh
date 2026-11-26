#!/usr/bin/env bash
set -euo pipefail

script=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zig-cache.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/zig-cache-test.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
failures=0

fail() {
    printf 'FAIL %s: %s\n' "$scenario" "$1" >&2
    failures=$((failures + 1))
}

restored_file() {
    mkdir -p -- "$(dirname "$1")"
    printf '%s' "${2:-$1}" > "$1"
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
    restored_file .zig-cache/h/global-manifest
    restored_file .zig-cache/o/global-output/libcompiler_rt.a
    restored_file .zig-cache/p/package.tar.gz
    restored_file .zig-cache/tmp/.tmp-leftover/file
    restored_file .zig-cache/local/build/h/hit
    restored_file .zig-cache/local/build/h/stale
    restored_file .zig-cache/local/build/h/configuration
    restored_file .zig-cache/local/build/h/timestamp
    restored_file .zig-cache/local/build/o/used/test
    restored_file .zig-cache/local/build/o/stale/test
    restored_file .zig-cache/local/build/c/configured
    restored_file .zig-cache/local/build/z/stale-zir
}

use() {
    local path
    for path in "$@"; do
        cat -- ".zig-cache/$path" > /dev/null
    done
}

compile() {
    mkdir -p -- ".zig-cache/$(dirname "$1")"
    printf '%s' "$1" > ".zig-cache/$1"
}

admit() {
    bash "$script" admit "$1" "${2:-1000000000}" > "$workspace/report"
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

begin certified
bash "$script" track > /dev/null
if [[ "$(< "$KOSMOS_CACHE_STATE/tracking")" != on ]]; then
    printf 'Access-time tracking is unavailable on this filesystem; cannot test pruning.\n' >&2
    exit 1
fi
use local/build/h/hit local/build/o/used/test local/build/h/configuration local/build/c/configured
compile local/build/o/new/test
compile local/build/h/new
admit qualified
expect_saved true
expect_present local/build/h/hit local/build/o/used/test local/build/h/configuration \
    local/build/c/configured local/build/o/new/test local/build/h/new local/build/h/timestamp \
    h/global-manifest o/global-output/libcompiler_rt.a p/package.tar.gz
expect_absent local/build/h/stale local/build/o/stale local/build/z/stale-zir tmp/.tmp-leftover
expect_report 'local/build: 9 units; 2 hit manifests; 2 read outputs; every hit output read; pruned 3 units'

begin unread-hit-output
bash "$script" track > /dev/null
use local/build/h/hit local/build/h/stale local/build/o/used/test
compile local/build/o/new/test
admit compiled
expect_saved true
expect_present local/build/h/stale local/build/o/stale/test local/build/z/stale-zir
expect_report '2 hit manifests; 1 read outputs; pruning withheld; pruned 0 units'

begin unchanged
bash "$script" track > /dev/null
use local/build/h/hit local/build/o/used/test local/build/h/stale
admit qualified
expect_saved false
expect_report 'equals the restored or saved entry; save skipped'

begin ceiling
bash "$script" track > /dev/null
compile local/build/o/new/test
admit qualified 1
expect_saved false
expect_report 'archive exceeds the lane maximum; save skipped, previous entry kept'

begin untracked
bash "$script" track > /dev/null
printf 'off\n' > "$KOSMOS_CACHE_STATE/tracking"
compile local/build/o/new/test
admit qualified
expect_saved true
expect_present local/build/h/stale local/build/o/stale/test local/build/z/stale-zir
expect_report 'pruning withheld; pruned 0 units'

begin phases
bash "$script" track > /dev/null
use local/build/h/hit local/build/h/configuration local/build/c/configured
compile local/build/o/new/test
admit compiled
expect_saved true
expect_present local/build/o/stale/test
find .zig-cache -type f -exec cat {} + > /dev/null
bash "$script" track > /dev/null
use local/build/o/used/test
admit qualified
expect_saved true
expect_present local/build/h/hit local/build/o/used/test local/build/c/configured local/build/o/new/test
expect_absent local/build/h/stale local/build/o/stale local/build/z/stale-zir
bash "$script" track > /dev/null
admit qualified
expect_saved false
expect_report 'equals the restored or saved entry; save skipped'

if (( failures > 0 )); then
    printf '%d compiler cache admission checks failed.\n' "$failures" >&2
    exit 1
fi
printf 'Compiler cache admission: all scenarios passed.\n'
