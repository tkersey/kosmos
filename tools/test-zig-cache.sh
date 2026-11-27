#!/usr/bin/env bash
set -euo pipefail

tools=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$tools/zig-cache.sh
workflow=$tools/../.github/workflows/runtime-bundle.yml
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

# A restored entry in Zig's layout: the build cache and Zig's global cache share .zig-cache, and
# the independent core rebuild keeps its own global cache and extracted packages beside them.
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

admit() {
    bash "$script" admit > "$workspace/report"
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

# Pairs keep a manifest with its output when the compilation read either; global units (builtins,
# package archives, compiler_rt and extracted packages) are pruned by use like build units.
begin pairs
bash "$script" track success > /dev/null
if [[ "$(< "$KOSMOS_CACHE_STATE/tracking")" != on ]]; then
    printf 'Access-time tracking is unavailable on this filesystem; cannot test pruning.\n' >&2
    exit 1
fi
use h/$m1 h/$m2 o/$f2/test c/$f3 z/used-zir b/used/builtin.zig p/used.tar.gz \
    native-driver-core/h/$m1 native-driver-core/zig-pkg/used/build.zig
admit
expect_saved true
expect_present h/$m1 o/$f1/test h/$m2 o/$f2/test h/$m3 c/$f3 z/used-zir h/timestamp \
    b/used/builtin.zig p/used.tar.gz native-driver-core/h/$m1 native-driver-core/o/$f1/test \
    native-driver-core/zig-pkg/used/build.zig
expect_absent h/$m4 o/$f4 o/orphan z/stale-zir h/$m5 h/$m6 h/$m8 o/$f8 b/stale p/stale.tar.gz \
    native-driver-core/zig-pkg/stale tmp/.tmp-leftover
expect_report 'Compiler cache root: 19 units; 5 manifest-output pairs; 2 manifests without output dropped; pruned 10 units'
expect_report 'Compiler cache native-driver-core/: 4 units; 1 manifest-output pairs; 0 manifests without output dropped; pruned 1 units'

begin written
bash "$script" track success > /dev/null
use h/$m1 o/$f1/test
write_manifest $m7
compile o/$f7/test
rewrite_unread z/stale-zir
admit
expect_saved true
expect_present h/$m1 o/$f1/test h/$m7 o/$f7/test z/stale-zir
expect_absent h/$m2 o/$f2 z/used-zir b/used p/used.tar.gz

# A failed restore is discarded; the compilation that follows writes, and saves, a complete set.
begin failed-restore
bash "$script" track failure > "$workspace/report"
expect_report 'Compiler cache restored (failure): 0 bytes'
expect_absent h/$m1 o/$f1 b/used p/used.tar.gz native-driver-core
write_manifest $m1
compile o/$f1/test
compile b/fresh/builtin.zig
compile p/fresh.tar.gz
admit
expect_saved true
expect_present h/$m1 o/$f1/test b/fresh/builtin.zig p/fresh.tar.gz
expect_report 'Compiler cache root: 4 units; 1 manifest-output pairs; 0 manifests without output dropped; pruned 0 units'

begin broken
rm -rf .zig-cache/o/$f2
bash "$script" track success > /dev/null
use h/$m1 o/$f1/test h/$m2
admit
expect_saved true
expect_absent h/$m2 o/$f2
expect_present h/$m1 o/$f1/test
expect_report '3 manifests without output dropped'

begin untracked
bash "$script" track success > /dev/null
printf 'off\n' > "$KOSMOS_CACHE_STATE/tracking"
admit
expect_saved false
expect_present h/$m4 o/$f4/test b/stale p/stale.tar.gz
expect_report '::warning::Compiler cache: reads leave no access time here'

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

# GitHub runs a step without a status function only after every earlier step succeeded, so a
# failed compilation saves nothing, and every key names the host target and the chosen CPU.
scenario=workflow
awk '
    /^  [a-z-]+:$/ { job = $1 }
    job == "qualify:" && /^      - / { steps++ }
    job == "qualify:" && /^      - name: / { sub(/^      - name: /, ""); name[steps] = $0 }
    job == "qualify:" && /^        name: / { sub(/^        name: /, ""); name[steps] = $0 }
    job == "qualify:" && /^        if: / { condition[steps] = $0 }
    END { for (i = 1; i <= steps; i++) printf "%d\t%s\t%s\n", i, name[i], condition[i] }
' "$workflow" > "$scratch/steps.tsv"
admission=$(awk -F '\t' '$2 ~ /^Prune the compiler cache/ { print $1 }' "$scratch/steps.tsv")
save=$(awk -F '\t' '$2 ~ /^Save the compiled lane/ { print $1 }' "$scratch/steps.tsv")
[[ -n "$admission" && "$save" == $((admission + 1)) ]] || fail "the save does not follow the admission"
if awk -F '\t' -v a="$admission" -v s="$save" '($1 == a || $1 == s) && $3 ~ /always\(\)|cancelled\(\)|failure\(\)/' \
    "$scratch/steps.tsv" | grep -q .; then
    fail "the admission or save runs after a failed step"
fi
if awk -F '\t' -v a="$admission" '$2 ~ /^Compile/ && $1 + 0 > a + 0' "$scratch/steps.tsv" | grep -q .; then
    fail "a compilation follows the save"
fi
grep -E '^ +(key: )?kosmos-native-' "$workflow" > "$scratch/keys.txt"
keys=$(wc -l < "$scratch/keys.txt")
complete=$(grep -F 'env.KOSMOS_HOST_TARGET' "$scratch/keys.txt" | grep -Fc 'env.KOSMOS_HOST_CPU')
(( keys == 7 && complete == keys )) || fail "$complete of $keys compiler cache keys name the host target and CPU"

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
    printf '%d compiler cache checks failed.\n' "$failures" >&2
    exit 1
fi
printf 'Compiler cache admission: all scenarios passed.\n'
