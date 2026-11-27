#!/usr/bin/env bash
set -euo pipefail

cache=.zig-cache
work_directory=${RUNNER_TEMP:?}
state=${KOSMOS_CACHE_STATE:-$work_directory/zig-cache-access}
pairs_source=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zig-cache-pairs.zig
unread_epoch=1
# Zig 0.17.1's x86_64_v3 ISA features beyond baseline, plus SHA, in Linux's cpuinfo names.
host_cpu_flags=(pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave sha_ni)

usage() {
    printf 'Usage: bash tools/zig-cache.sh host-cpu < /proc/cpuinfo\n' >&2
    printf '       bash tools/zig-cache.sh track success|failure|cancelled|skipped\n' >&2
    printf '       bash tools/zig-cache.sh admit\n' >&2
    exit 64
}

tree_bytes() {
    find "$1" -type f -printf '%s\n' | awk '{ n += $1 } END { printf "%.0f", n }'
}

host_cpu() {
    local flags flag
    flags=" $(awk -F ':' '$1 ~ /^flags[[:space:]]*$/ { print $2; exit }') "
    for flag in "${host_cpu_flags[@]}"; do
        if [[ "$flags" != *" $flag "* ]]; then
            printf 'baseline\n'
            return 0
        fi
    done
    printf 'x86_64_v3+sha\n'
}

access_time_tracking() {
    local probe=$cache/tmp/access-probe
    printf 'probe' > "$probe"
    touch -a -d "@$unread_epoch" -- "$probe"
    cat -- "$probe" > /dev/null
    local accessed
    accessed=$(stat -c %X -- "$probe")
    rm -f -- "$probe"
    if (( accessed > unread_epoch )); then
        printf 'on\n'
    else
        printf 'off\n'
    fi
}

track() {
    # A failed or timed-out restore may have extracted part of an entry; compile from nothing instead.
    if [[ "$1" != success ]]; then
        rm -rf -- "$cache"
    fi
    mkdir -p -- "$state" "$cache/tmp"
    access_time_tracking > "$state/tracking"
    printf 'Compiler cache restored (%s): %s bytes; access tracking %s\n' \
        "$1" "$(tree_bytes "$cache")" "$(< "$state/tracking")"
    if [[ "$(< "$state/tracking")" == on ]]; then
        find "$cache" -type f -exec touch -a -d "@$unread_epoch" -- {} +
    fi
    # Mark on the cache's own change-time clock, then wait out its tick so every later write follows.
    local mark=$cache/tmp/armed-mark
    touch -- "$mark"
    find "$mark" -printf '%C@\n' > "$state/armed"
    touch -- "$mark"
    while [[ "$(find "$mark" -printf '%C@')" == "$(< "$state/armed")" ]]; do
        sleep 0.001
        touch -- "$mark"
    done
    rm -f -- "$mark"
}

# A unit is a manifest, output, configuration, ZIR file, builtin module, package archive or
# extracted package of the cache root ("" or a named subcache such as "native-owners/").
unit_program='
    function unit(path,    part, n, k) {
        n = split(path, part, "/")
        k = (part[1] ~ kinds) ? 1 : 2
        root = (k == 1) ? "" : part[1] "/"
        kind = part[k]
        if (n <= k || kind !~ kinds) return ""
        if (kind == "h" && (n != k + 1 || part[n] == "timestamp")) return ""
        return root kind "/" part[k + 1]
    }
'
unit_kinds='^(h|o|c|z|b|p|zig-pkg)$'

pair_manifests() {
    awk -F '\t' -v kinds="$unit_kinds" "$unit_program"'{ if (unit($4) != "" && kind == "h") print unit($4) }' \
        "$state/listing" |
        zig run --cache-dir "$work_directory/zig-cache-pairs/local" \
            --global-cache-dir "$work_directory/zig-cache-pairs/global" \
            "$pairs_source" -- "$cache" > "$state/pairs"
}

# Keep a manifest and its output together when the compilation read or wrote either; keep any
# other unit it read or wrote; prune the rest and every manifest that names no existing output.
classify_units() {
    awk -F '\t' \
        -v kinds="$unit_kinds" \
        -v armed="$(< "$state/armed")" \
        -v unread="$unread_epoch" \
        -v pairs_in="$state/pairs" \
        -v prune_out="$state/prune" "$unit_program"'
        BEGIN {
            while ((getline line < pairs_in) > 0) {
                split(line, field, "\t")
                output_of[field[1]] = field[2]
                if (field[2] != "") manifest_of[field[2]] = field[1]
            }
            close(pairs_in)
        }
        {
            name = unit($4)
            if (name == "") next
            unit_root[name] = root
            unit_bytes[name] += $3
            if ($1 + 0 > unread + 0.5 || $2 + 0 > armed + 0) used[name] = 1
        }
        END {
            printf "" > prune_out
            for (name in unit_root) {
                group[name] = (name in manifest_of) ? manifest_of[name] : name
                if (name in used) group_used[group[name]] = 1
            }
            for (name in unit_root) {
                root = unit_root[name]
                units[root]++
                broken = (group[name] in output_of) && output_of[group[name]] == ""
                if ((name in output_of) && !broken) pairs[root]++
                if ((name in output_of) && broken) dropped[root]++
                if (!broken && (group[name] in group_used)) continue
                print name > prune_out
                if ((name in output_of) && output_of[name] != "") print output_of[name] > prune_out
                pruned[root]++
                pruned_bytes[root] += unit_bytes[name]
            }
            for (root in units) {
                printf "Compiler cache %s: %d units; %d manifest-output pairs; %d manifests without output dropped; pruned %d units (%.0f bytes)\n", \
                    root == "" ? "root" : root, units[root], pairs[root], dropped[root], \
                    pruned[root], pruned_bytes[root]
            }
        }
    ' "$state/listing"
}

admit() {
    local output=${GITHUB_OUTPUT:-/dev/null}
    printf 'save=false\n' >> "$output"
    if [[ ! -e "$state/armed" || ! -d "$cache" ]]; then
        printf 'Compiler cache: untracked; save skipped\n'
        return 0
    fi
    if [[ "$(< "$state/tracking")" != on ]]; then
        printf '::warning::Compiler cache: reads leave no access time here, so the cache cannot be pruned to what the compilation used; save skipped\n'
        return 0
    fi
    if [[ -n "$(find "$cache" ! -type d ! -type f -print -quit)" ]]; then
        printf 'Compiler cache: nonregular file; save skipped\n'
        return 0
    fi
    # List before pairing: the pairing tool reads manifests and would mark them read.
    find "$cache" -type f -printf '%A@\t%C@\t%s\t%P\n' > "$state/listing"
    pair_manifests
    classify_units
    local unit directory
    while IFS= read -r unit; do
        rm -rf -- "${cache:?}/$unit"
    done < "$state/prune"
    for directory in "$cache/tmp" "$cache"/*/tmp; do
        if [[ -d "$directory" ]]; then
            find "$directory" -mindepth 1 -delete
        fi
    done
    printf 'Compiler cache: save %s bytes\n' "$(tree_bytes "$cache")"
    printf 'save=true\n' >> "$output"
}

case "${1:-}" in
    host-cpu)
        [[ $# -eq 1 ]] || usage
        host_cpu
        ;;
    track)
        [[ $# -eq 2 && "$2" =~ ^(success|failure|cancelled|skipped)$ ]] || usage
        track "$2"
        ;;
    admit)
        [[ $# -eq 1 ]] || usage
        admit
        ;;
    *)
        usage
        ;;
esac
