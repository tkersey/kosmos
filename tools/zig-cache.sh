#!/usr/bin/env bash
set -euo pipefail

cache=.zig-cache
record=$cache/kosmos-cache-record
work_directory=${RUNNER_TEMP:?}
state=${KOSMOS_CACHE_STATE:-$work_directory/zig-cache-access}
aside=$state/aside
tool_root=tools/
pairs_source=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zig-cache-pairs.zig
unread_epoch=1
save_bytes_max=${KOSMOS_CACHE_BYTES_MAX:-1000000000}
host_cpu_flags=(pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave sha_ni)

usage() {
    printf 'Usage: bash tools/zig-cache.sh host-cpu < /proc/cpuinfo\n' >&2
    printf '       bash tools/zig-cache.sh track success|failure|cancelled|skipped\n' >&2
    printf '       bash tools/zig-cache.sh stage|unstage|admit\n' >&2
    exit 64
}

tree_bytes() {
    find "$1" -type f -printf '%s\n' | awk '{ n += $1 } END { printf "%.0f", n }'
}

tree_record() {
    find "$cache" -type f ! -path "$record" -printf '%s %P\n' | LC_ALL=C sort
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

pairs() {
    zig run -fstrip --cache-dir "$cache/$tool_root" \
        ${KOSMOS_HOST_TARGET:+-target "$KOSMOS_HOST_TARGET"} \
        ${KOSMOS_HOST_CPU:+-mcpu "$KOSMOS_HOST_CPU"} \
        "$pairs_source" -- "$cache"
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

arm() {
    mkdir -p -- "$cache/tmp"
    access_time_tracking > "$state/tracking"
    if [[ "$(< "$state/tracking")" == on ]]; then
        find "$cache" -type f -exec touch -a -d "@$unread_epoch" -- {} +
    fi
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

track() {
    if [[ "$1" != success ]]; then
        rm -rf -- "$cache"
    elif [[ -e "$cache" ]] && ! { [[ -f "$record" ]] && cmp -s -- "$record" <(tree_record); }; then
        printf '::warning::Compiler cache: the restored tree differs from its record; compiling from nothing\n'
        rm -rf -- "$cache"
    fi
    rm -f -- "$record"
    rm -rf -- "$state"
    mkdir -p -- "$state" "$cache"
    arm
    printf 'Compiler cache restored (%s): %s bytes; access tracking %s\n' \
        "$1" "$(tree_bytes "$cache")" "$(< "$state/tracking")"
    if ! pairs < /dev/null > /dev/null; then
        printf '::warning::Compiler cache: the pairing tool failed to build; nothing will be saved\n'
    fi
}

unit_program='
    function unit(path,    part, n, k) {
        n = split(path, part, "/")
        k = (part[1] ~ kinds) ? 1 : 2
        root = (k == 1) ? "" : part[1] "/"
        kind = part[k]
        if (n <= k || kind !~ kinds) return ""
        if (kind == "h" && (n != k + 1 || part[n] == "timestamp")) return ""
        maker = (kind == "o" && n == k + 2 && part[n] == "maker")
        return root kind "/" part[k + 1]
    }
'
unit_kinds='^(h|o|c|z|b|p|zig-pkg)$'

classify_units() {
    awk -F '\t' \
        -v kinds="$unit_kinds" \
        -v armed="$(< "$state/armed")" \
        -v unread="$unread_epoch" \
        -v pairs_in="$state/pairs" \
        -v earlier_in="$state/earlier" \
        -v tool_root="$tool_root" \
        -v kept_out="$state/kept" \
        -v prune_out="$state/prune" "$unit_program"'
        BEGIN {
            while ((getline line < pairs_in) > 0) {
                fields = split(line, field, "\t")
                output_of[field[1]] = field[2]
                if (field[2] != "") manifest_of[field[2]] = field[1]
                inputs[field[1]] = fields - 2
                for (i = 3; i <= fields; i++) input[field[1], i - 2] = field[i]
            }
            close(pairs_in)
        }
        {
            name = unit($4)
            if (name == "") next
            unit_root[name] = root
            unit_bytes[name] += $3
            if (maker) runner[name] = 1
            if ($1 + 0 > unread + 0.5 || $2 + 0 > armed + 0) used[name] = 1
        }
        END {
            while ((getline name < earlier_in) > 0) if (name in unit_root) used[name] = 1
            printf "" > kept_out
            printf "" > prune_out
            for (name in unit_root) {
                group[name] = (name in manifest_of) ? manifest_of[name] : name
                if (name in used) group_used[group[name]] = 1
                if (name in runner) group_runner[group[name]] = 1
            }
            for (name in unit_root) {
                broken[name] = (group[name] in output_of) && output_of[group[name]] == ""
                kept[name] = !broken[name] && (group[name] in group_used || group[name] in group_runner)
            }
            for (name in output_of) {
                if (!(name in unit_root) || !kept[name]) continue
                if ((name in group_used) && unit_root[name] != tool_root) used_pairs++
                for (i = 1; i <= inputs[name]; i++) {
                    path = unit_root[name] input[name, i]
                    if (!(unit(path) in unit_root)) path = input[name, i]
                    needed[unit(path)] = 1
                }
            }
            for (name in needed) {
                if (!(name in unit_root) || broken[name]) continue
                kept[name] = 1
                if (name in manifest_of) kept[manifest_of[name]] = 1
            }
            for (name in unit_root) {
                root = unit_root[name]
                units[root]++
                if ((name in output_of) && !broken[name]) pairs[root]++
                if ((name in output_of) && broken[name]) dropped[root]++
                if (name in runner && kept[name]) runners[root]++
                if (kept[name]) {
                    print name > kept_out
                    continue
                }
                print name > prune_out
                pruned[root]++
                pruned_bytes[root] += unit_bytes[name]
            }
            for (root in units) {
                printf "Compiler cache %s: %d units; %d manifest-output pairs; %d manifests without output dropped; %d build runners kept; pruned %d units (%.0f bytes)\n", \
                    root == "" ? "root" : root, units[root], pairs[root], dropped[root], \
                    runners[root], pruned[root], pruned_bytes[root]
            }
            if (used_pairs == 0) exit 3
        }
    ' "$state/listing"
}

classify() {
    local output=${GITHUB_OUTPUT:-/dev/null}
    printf 'save=false\n' >> "$output"
    if [[ ! -e "$state/armed" || ! -d "$cache" ]]; then
        printf 'Compiler cache: untracked; save skipped\n'
        return 1
    fi
    if [[ "$(< "$state/tracking")" != on ]]; then
        printf '::warning::Compiler cache: reads leave no access time here, so the cache cannot be pruned to what the job used; save skipped\n'
        return 1
    fi
    if [[ -n "$(find "$cache" ! -type d ! -type f -print -quit)" ]]; then
        printf 'Compiler cache: nonregular file; save skipped\n'
        return 1
    fi
    find "$cache" -type f -printf '%A@\t%C@\t%s\t%P\n' > "$state/listing"
    awk -F '\t' -v kinds="$unit_kinds" "$unit_program"'{ if (unit($4) != "" && kind == "h") print unit($4) }' \
        "$state/listing" > "$state/manifests"
    if ! pairs < "$state/manifests" > "$state/pairs"; then
        printf '::warning::Compiler cache: the pairing tool failed; save skipped\n'
        return 1
    fi
    touch -- "$state/earlier"
    local status=0
    classify_units || status=$?
    if (( status == 3 )); then
        printf '::warning::Compiler cache: the job used no compiled output; save skipped\n'
    elif (( status != 0 )); then
        printf '::warning::Compiler cache: classification failed; save skipped\n'
    fi
    return "$status"
}

seal() {
    local directory bytes
    for directory in "$cache/tmp" "$cache"/*/tmp; do
        if [[ -d "$directory" ]]; then
            find "$directory" -mindepth 1 -delete
        fi
    done
    bytes=$(tree_bytes "$cache")
    if (( bytes > save_bytes_max )); then
        printf '::warning::Compiler cache: %s bytes exceed the %s-byte ceiling; save skipped\n' \
            "$bytes" "$save_bytes_max"
        return 0
    fi
    tree_record > "$record"
    printf 'Compiler cache: save %s bytes\n' "$bytes"
    printf 'save=true\n' >> "${GITHUB_OUTPUT:-/dev/null}"
}

stage() {
    classify || return 0
    local unit
    while IFS= read -r unit; do
        mkdir -p -- "$(dirname -- "$aside/$unit")"
        mv -- "$cache/$unit" "$aside/$unit"
    done < "$state/prune"
    seal
}

unstage() {
    rm -f -- "$record"
    if [[ ! -f "$state/kept" ]]; then
        return 0
    fi
    local unit
    while IFS= read -r unit; do
        if [[ -e "$aside/$unit" ]]; then
            mkdir -p -- "$(dirname -- "$cache/$unit")"
            mv -- "$aside/$unit" "$cache/$unit"
        fi
    done < "$state/prune"
    rm -rf -- "$aside"
    cat -- "$state/kept" >> "$state/earlier"
    arm
}

admit() {
    classify || return 0
    local unit
    while IFS= read -r unit; do
        rm -rf -- "${cache:?}/$unit"
    done < "$state/prune"
    seal
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
    stage | unstage | admit)
        [[ $# -eq 1 ]] || usage
        "$1"
        ;;
    *)
        usage
        ;;
esac
