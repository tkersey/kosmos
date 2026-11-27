#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

cache=.zig-cache
record=$cache/kosmos-cache-record
history=$cache/kosmos-build-runners
saved=$cache.saved
restored=$cache.restored
pairs_source=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zig-cache-pairs.zig
output=${GITHUB_OUTPUT:-/dev/null}
unread_epoch=1
save_bytes_max=${KOSMOS_CACHE_BYTES_MAX:-1000000000}
build_runner_jobs_max=6
step_seconds_max=${KOSMOS_CACHE_STEP_SECONDS_MAX:-20}
kill_seconds=1
stop_seconds_max=$(( step_seconds_max / 2 ))
host_cpu_flags=(pni ssse3 sse4_1 sse4_2 popcnt cx16 lahf_lm avx avx2 bmi1 bmi2 f16c fma abm movbe xsave sha_ni)
mark=

usage() {
    printf 'Usage: bash tools/zig-cache.sh host-cpu < /proc/cpuinfo\n' >&2
    printf '       bash tools/zig-cache.sh tool\n' >&2
    printf '       bash tools/zig-cache.sh track success|failure|cancelled|skipped\n' >&2
    printf '       bash tools/zig-cache.sh stage|unstage|admit\n' >&2
    exit 64
}

tree_bytes() {
    find "$1" -type f -printf '%s\n' | awk '{ n += $1 } END { printf "%.0f", n }'
}

tree_record() {
    find "$1" -type f ! -path "$1/kosmos-cache-record" -printf '%s %P\n' | LC_ALL=C sort
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
    "$pairs_tool" "$cache"
}

tool() {
    rm -f -- "$pairs_tool"
    mkdir -p -- "$tool_dir"
    zig build-exe -fstrip --cache-dir "$tool_dir/local" --global-cache-dir "$tool_dir/global" \
        ${KOSMOS_HOST_TARGET:+-target "$KOSMOS_HOST_TARGET"} \
        ${KOSMOS_HOST_CPU:+-mcpu "$KOSMOS_HOST_CPU"} \
        -femit-bin="$tool_dir/building" "$pairs_source"
    mv -- "$tool_dir/building" "$pairs_tool"
    printf 'Compiler cache: built the pairing tool\n'
}

limit() {
    local status=0 started=$SECONDS elapsed
    KOSMOS_CACHE_LIMITED=1 timeout -k "$kill_seconds" "$step_seconds_max" bash "${BASH_SOURCE[0]}" "$@" ||
        status=$?
    elapsed=$(( SECONDS - started ))
    if (( status == 124 )); then
        printf '::warning::Compiler cache: %s exceeded its %d s limit and was stopped; this job saves no further compiler cache\n' \
            "$mode" "$step_seconds_max"
    elif (( status == 137 && elapsed >= step_seconds_max )); then
        printf '::warning::Compiler cache: %s exceeded its %d s limit and was killed; this job saves no further compiler cache\n' \
            "$mode" "$step_seconds_max"
    elif (( status == 137 )); then
        printf '::warning::Compiler cache: %s was killed after %d s, before its %d s limit; this job saves no further compiler cache\n' \
            "$mode" "$elapsed" "$step_seconds_max"
    elif (( status != 0 )); then
        printf '::warning::Compiler cache: %s failed with status %d; this job saves no further compiler cache\n' \
            "$mode" "$status"
    fi
    if [[ "$mode" == track && -e "$restored" ]]; then
        discard
    fi
    exit "$status"
}

discard() {
    local status=0
    timeout -k "$kill_seconds" "$step_seconds_max" rm -rf -- "$restored" || status=$?
    if (( status == 0 )); then
        printf 'Compiler cache: deleted the unverified restored tree\n'
    else
        printf '::warning::Compiler cache: deleting the unverified restored tree stopped or failed with status %d; it stays in the workspace\n' \
            "$status"
    fi
}

begin() {
    mode=$1
    skipped=$2
    shift 2
    state=${KOSMOS_CACHE_STATE:-${RUNNER_TEMP:?}/zig-cache-access}
    aside=$state/aside
    tool_dir=${RUNNER_TEMP:?}/zig-cache-pairs
    pairs_tool=$tool_dir/zig-cache-pairs
    if [[ -z "${KOSMOS_CACHE_LIMITED:-}" ]]; then
        if [[ "$mode" == stage || "$mode" == admit ]]; then
            printf 'save=false\n' >> "$output"
        fi
        limit "$@"
    fi
}

skip() {
    printf '%s; %s\n' "$1" "$skipped"
    if [[ -n "$mark" ]]; then
        give
    fi
    exit 0
}

take() {
    if [[ -e "$state/armed" ]]; then
        mark=$(< "$state/armed")
        rm -f -- "$state/armed"
    fi
}

give() {
    printf '%s\n' "$mark" > "$state/armed.next"
    mv -- "$state/armed.next" "$state/armed"
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
    local tracking probe=$cache/tmp/armed-mark changed
    mkdir -p -- "$cache/tmp"
    tracking=$(access_time_tracking)
    if [[ "$tracking" == on ]]; then
        find "$cache" -type f -exec touch -a -d "@$unread_epoch" -- {} +
    fi
    touch -- "$probe"
    mark=$(find "$probe" -printf '%C@')
    changed=$mark
    while [[ "$changed" == "$mark" ]]; do
        sleep 0.001
        touch -- "$probe"
        changed=$(find "$probe" -printf '%C@')
    done
    rm -f -- "$probe"
    printf '%s\n' "$tracking" > "$state/tracking"
}

stop() {
    local id=${RUNNER_TRACKING_ID:-} line pid name note ancestor deadline left names=
    local -A ours=() stopped=()
    if [[ -z "$id" ]]; then
        skip "::warning::Compiler cache: RUNNER_TRACKING_ID is unset, so $mode cannot stop what earlier steps left running"
    fi
    ancestor=$$
    while (( ancestor > 0 )); do
        ours[$ancestor]=1
        read -r line < "/proc/$ancestor/stat"
        line=${line##*) }
        read -r _ ancestor _ <<< "$line"
    done
    deadline=$(( SECONDS + stop_seconds_max ))
    while :; do
        grep -lsxzF -- "RUNNER_TRACKING_ID=$id" /proc/[0-9]*/environ > "$state/tracked" || :
        if ! grep -Fxq -- "/proc/$$/environ" "$state/tracked"; then
            skip "::warning::Compiler cache: this job's processes cannot be listed, so $mode cannot stop what earlier steps left running"
        fi
        left=0
        while IFS= read -r line; do
            pid=${line#/proc/}
            pid=${pid%/environ}
            if [[ -n "${ours[$pid]:-}" ]] || ! grep -qsxzF -- "RUNNER_TRACKING_ID=$id" "/proc/$pid/environ"; then
                continue
            fi
            name=
            read -r name 2> /dev/null < "/proc/$pid/comm" || :
            note=
            if ! kill -KILL -- "$pid" 2> /dev/null; then
                if ! grep -qsxzF -- "RUNNER_TRACKING_ID=$id" "/proc/$pid/environ"; then
                    continue
                fi
                note='(SIGKILL failed)'
            fi
            left=1
            if [[ -z "${stopped[$pid]:-}" ]]; then
                stopped[$pid]=1
                names+=" ${name:-?}[${pid}]${note}"
            fi
        done < "$state/tracked"
        (( left )) || break
        if (( SECONDS >= deadline )); then
            skip "::warning::Compiler cache: what earlier steps left running did not exit within ${stop_seconds_max} s of SIGKILL:${names}"
        fi
        sleep 0.01
    done
    if [[ -n "$names" ]]; then
        printf '::warning::Compiler cache: stopped what earlier steps left running:%s\n' "$names"
    fi
}

track() {
    local bytes tracking
    rm -rf -- "$state"
    mkdir -p -- "$state"
    if [[ -e "$saved" ]]; then
        mv -T -- "$saved" "$restored"
    fi
    stop
    rm -rf -- "$saved"
    if [[ "$1" == success && -f "$restored/kosmos-cache-record" ]]; then
        tree_record "$restored" > "$state/restored-record"
        if cmp -s -- "$restored/kosmos-cache-record" "$state/restored-record"; then
            mv -T -- "$restored" "$cache"
        fi
    fi
    if [[ -e "$restored" ]]; then
        if [[ "$1" == success ]]; then
            printf '::warning::Compiler cache: the restored tree differs from its record; compiling from nothing\n'
        fi
        rm -rf -- "$restored"
    fi
    rm -f -- "$record"
    mkdir -p -- "$cache"
    if [[ -f "$history" ]]; then
        mv -- "$history" "$state/runners"
    else
        : > "$state/runners"
    fi
    arm
    bytes=$(tree_bytes "$cache")
    tracking=$(< "$state/tracking")
    printf 'Compiler cache restored (%s): %s bytes; access tracking %s\n' "$1" "$bytes" "$tracking"
    give
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
        -v armed="$mark" \
        -v unread="$unread_epoch" \
        -v pairs_in="$state/pairs" \
        -v earlier_in="$state/earlier" \
        -v history_in="$state/runners" \
        -v history_max="$build_runner_jobs_max" \
        -v kept_out="$state/kept" \
        -v used_out="$state/used" \
        -v history_out="$state/history" \
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
            while (history_lines < history_max - 1 && (getline line < history_in) > 0) {
                history[++history_lines] = line
                fields = split(line, field, "\t")
                for (i = 1; i <= fields; i++) retained[field[i]] = 1
            }
            close(history_in)
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
            printf "" > used_out
            printf "" > prune_out
            for (name in unit_root) {
                group[name] = (name in manifest_of) ? manifest_of[name] : name
                if (name in used) group_used[group[name]] = 1
                if ((name in runner) && (name in retained)) group_retained[group[name]] = 1
            }
            for (name in unit_root) {
                broken[name] = (group[name] in output_of) && output_of[group[name]] == ""
                kept[name] = !broken[name] && (group[name] in group_used || group[name] in group_retained)
                if (!broken[name] && group[name] in group_used) print name > used_out
            }
            for (name in output_of) {
                if (!(name in unit_root) || !kept[name]) continue
                if (name in group_used) used_pairs++
                queue[++queued] = name
                queued_manifest[name] = 1
            }
            for (q = 1; q <= queued; q++) {
                name = queue[q]
                for (i = 1; i <= inputs[name]; i++) {
                    path = unit_root[name] input[name, i]
                    if (!(unit(path) in unit_root)) path = input[name, i]
                    need = unit(path)
                    if (!(need in unit_root) || broken[need]) continue
                    kept[need] = 1
                    manifest = (need in manifest_of) ? manifest_of[need] : need
                    if (!(manifest in output_of) || (manifest in queued_manifest)) continue
                    kept[manifest] = 1
                    queue[++queued] = manifest
                    queued_manifest[manifest] = 1
                }
            }
            line = ""
            for (name in runner) {
                if (kept[name] && group[name] in group_used) line = line (line == "" ? "" : "\t") name
            }
            print line > history_out
            for (i = 1; i <= history_lines; i++) {
                fields = split(history[i], field, "\t")
                line = ""
                for (j = 1; j <= fields; j++) {
                    name = field[j]
                    if ((name in unit_root) && kept[name]) line = line (line == "" ? "" : "\t") name
                }
                print line > history_out
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
                pruned[root]++
                pruned_bytes[root] += unit_bytes[name]
                if (name in output_of) print name > prune_out
                else later[++laters] = name
            }
            for (i = 1; i <= laters; i++) print later[i] > prune_out
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
    local tracking nonregular status=0
    if [[ -z "$mark" || ! -d "$cache" ]]; then
        skip 'Compiler cache: untracked, or an earlier compiler cache step failed'
    fi
    tracking=$(< "$state/tracking")
    if [[ "$tracking" != on ]]; then
        skip '::warning::Compiler cache: reads leave no access time here, so the cache cannot be pruned to what the job used'
    fi
    nonregular=$(find "$cache" ! -type d ! -type f -print -quit)
    if [[ -n "$nonregular" ]]; then
        skip 'Compiler cache: nonregular file'
    fi
    find "$cache" -type f -printf '%A@\t%C@\t%s\t%P\n' > "$state/listing"
    awk -F '\t' -v kinds="$unit_kinds" "$unit_program"'{ if (unit($4) != "" && kind == "h") print unit($4) }' \
        "$state/listing" > "$state/manifests"
    if ! pairs < "$state/manifests" > "$state/pairs"; then
        skip '::warning::Compiler cache: the pairing tool failed'
    fi
    touch -- "$state/earlier" "$state/runners"
    classify_units || status=$?
    if (( status == 3 )); then
        skip '::warning::Compiler cache: the job used no compiled output'
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
    cp -- "$state/history" "$history"
    bytes=$(tree_bytes "$cache")
    if (( bytes > save_bytes_max )); then
        skip "::warning::Compiler cache: ${bytes} bytes exceed the ${save_bytes_max}-byte ceiling"
    fi
    tree_record "$cache" > "$record"
    : > "$state/sealed"
    mv -T -- "$cache" "$saved"
    give
    printf 'Compiler cache: save %s bytes\n' "$bytes"
    printf 'save=true\n' >> "$output"
}

stage() {
    local unit
    take
    classify
    while IFS= read -r unit; do
        mkdir -p -- "$(dirname -- "$aside/$unit")"
        mv -T -- "$cache/$unit" "$aside/$unit"
    done < "$state/prune"
    seal
}

unstage() {
    local unit held
    take
    if [[ -e "$state/sealed" && -e "$saved" ]]; then
        mv -T -- "$saved" "$cache"
    fi
    rm -f -- "$state/sealed" "$record" "$history"
    if [[ -f "$state/prune" ]]; then
        tac -- "$state/prune" > "$state/return"
        while IFS= read -r unit; do
            if [[ -e "$aside/$unit" ]]; then
                mkdir -p -- "$(dirname -- "$cache/$unit")"
                mv -T -- "$aside/$unit" "$cache/$unit"
            fi
        done < "$state/return"
    fi
    rm -rf -- "$aside"
    if [[ -z "$mark" ]]; then
        printf 'Compiler cache: untracked, or an earlier compiler cache step failed\n'
        return 0
    fi
    if [[ -f "$state/used" ]]; then
        held=$mark
        mark=
        stop
        mark=$held
        cat -- "$state/used" >> "$state/earlier"
        arm
    fi
    give
}

admit() {
    local unit
    take
    classify
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
    tool)
        [[ $# -eq 1 ]] || usage
        begin "$1" 'the pairing tool is not built and this job saves no compiler cache' "$@"
        tool
        ;;
    track)
        [[ $# -eq 2 && "$2" =~ ^(success|failure|cancelled|skipped)$ ]] || usage
        begin "$1" 'this job uses no restored tree and saves no compiler cache' "$@"
        track "$2"
        ;;
    stage | admit)
        [[ $# -eq 1 ]] || usage
        begin "$1" 'save skipped' "$@"
        "$1"
        ;;
    unstage)
        [[ $# -eq 1 ]] || usage
        begin "$1" 'this job saves no further compiler cache' "$@"
        unstage
        ;;
    *)
        usage
        ;;
esac
