#!/usr/bin/env bash
set -euo pipefail

cache=.zig-cache
snapshot=.zig-cache-upload
work_directory=${RUNNER_TEMP:?}
state=${KOSMOS_CACHE_STATE:-$work_directory/zig-cache-access}
pairs_source=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/zig-cache-pairs.zig
unread_epoch=1
archive_timestamp_slack_bytes=1048576
deadline_kill_seconds=10

usage() {
    printf 'Usage: bash tools/zig-cache.sh track\n' >&2
    printf '       KOSMOS_LANE_DEADLINE=EPOCH_SECONDS bash tools/zig-cache.sh work STEP_SCRIPT\n' >&2
    printf '       bash tools/zig-cache.sh admit ARCHIVE_BYTES_MAX success|failure|cancelled\n' >&2
    exit 64
}

tree_bytes() {
    if [[ -d "$1" ]]; then
        find "$1" -type f -printf '%s\n' | awk '{ n += $1 } END { printf "%.0f", n }'
    else
        printf '0'
    fi
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
    rm -rf -- "$snapshot"
    mkdir -p -- "$state" "$cache/tmp"
    access_time_tracking > "$state/tracking"
    printf 'Compiler cache restored: %s bytes; access tracking %s\n' \
        "$(tree_bytes "$cache")" "$(< "$state/tracking")"
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

work() {
    local deadline=$KOSMOS_LANE_DEADLINE remaining status=0
    remaining=$(( deadline - $(date +%s) ))
    if (( remaining > 0 )); then
        timeout --kill-after="$deadline_kill_seconds" "$remaining" \
            bash --noprofile --norc -eo pipefail "$1" || status=$?
    else
        status=124
    fi
    if (( status != 0 && $(date +%s) >= deadline )); then
        printf '::error::Lane work reached its deadline; the compiler cache is still admitted\n'
        status=124
    fi
    return "$status"
}

unit_program='
    function unit(path,    part, n, k) {
        n = split(path, part, "/")
        k = (part[1] == "local") ? 3 : ((part[1] ~ /^(h|o|c|z)$/) ? 1 : 2)
        root = (k == 1) ? "" : ((k == 2) ? part[1] "/" : part[1] "/" part[2] "/")
        kind = part[k]
        if (n <= k || kind !~ /^(h|o|c|z)$/) return ""
        if (kind == "h" && (n != k + 1 || part[n] == "timestamp")) return ""
        return root kind "/" part[k + 1]
    }
'

pair_manifests() {
    awk -F '\t' "$unit_program"'{ if (unit($4) != "" && kind == "h") print unit($4) }' \
        "$state/listing" |
        zig run --cache-dir "$work_directory/zig-cache-pairs/local" \
            --global-cache-dir "$work_directory/zig-cache-pairs/global" \
            "$pairs_source" -- "$cache" > "$state/pairs"
}

classify_units() {
    awk -F '\t' \
        -v scope="$1" \
        -v armed="$(< "$state/armed")" \
        -v tracking="$(< "$state/tracking")" \
        -v unread="$unread_epoch" \
        -v pairs_in="$state/pairs" \
        -v prune_out="$state/prune" \
        -v changes_out="$state/changes" "$unit_program"'
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
            if ($2 + 0 > armed + 0) written[name] = 1
            if ((name in written) || (tracking == "on" && $1 + 0 > unread + 0.5)) used[name] = 1
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
                manifest = (name in output_of)
                broken = (group[name] in output_of) && output_of[group[name]] == ""
                prunable = tracking == "on" && scope != "no" && (scope == "all" || root ~ /^local\//)
                if (manifest && !broken) pairs[root]++
                if (manifest && broken) dropped[root]++
                if (manifest && broken && !(name in written)) changes++
                if (!broken && (!prunable || (group[name] in group_used))) {
                    if (name in written) kept_written[root]++
                    continue
                }
                print name > prune_out
                if (manifest && output_of[name] != "") print output_of[name] > prune_out
                pruned[root]++
                pruned_bytes[root] += unit_bytes[name]
            }
            for (root in units) {
                printf "Compiler cache %s: %d units; %d manifest-output pairs; %d manifests without output dropped; pruned %d units (%.0f bytes); kept %d written units\n", \
                    root == "" ? "global" : root, units[root], pairs[root], dropped[root], \
                    pruned[root], pruned_bytes[root], kept_written[root]
                changes += kept_written[root]
            }
            print changes + 0 > changes_out
        }
    ' "$state/listing"
}

take_snapshot() {
    rm -rf -- "$snapshot"
    cp -al -- "$cache" "$snapshot"
    while IFS= read -r unit; do
        rm -rf -- "${snapshot:?}/$unit"
    done < "$state/prune"
    local directory
    for directory in "$snapshot/tmp" "$snapshot"/*/tmp "$snapshot"/local/*/tmp; do
        if [[ -d "$directory" ]]; then
            find "$directory" -mindepth 1 -delete
        fi
    done
}

admit() {
    local archive_bytes_max=$1 lane=$2
    local output=${GITHUB_OUTPUT:-/dev/null}
    printf 'save=false\n' >> "$output"
    if [[ ! -e "$state/armed" || ! -d "$cache" ]]; then
        printf 'Compiler cache: untracked; save skipped\n'
        return 0
    fi
    if [[ -n "$(find "$cache" ! -type d ! -type f -print -quit)" ]]; then
        printf 'Compiler cache: nonregular file; save skipped\n'
        return 0
    fi
    find "$cache" -type f -printf '%A@\t%C@\t%s\t%P\n' > "$state/listing"
    pair_manifests
    # A failed lane may stop before reading what its rerun needs, so only a successful lane's reads prune.
    local scopes=(no) admitted='restored entry and every write'
    if [[ "$lane" == success ]]; then
        scopes=(build all)
        admitted='what this run used'
    fi
    local scope archive_bytes
    for scope in "${scopes[@]}"; do
        classify_units "$scope"
        if [[ "$lane" != success && "$(< "$state/changes")" == 0 ]]; then
            printf 'Compiler cache: lane failed without writing a kept unit or dropping a restored manifest; save skipped, previous entry kept\n'
            return 0
        fi
        take_snapshot
        archive_bytes=$(tar --posix -cf - -P -C "$PWD" "$snapshot" | zstd -T0 -q -c | wc -c)
        printf 'Compiler cache (%s caches pruned): cache %s bytes; snapshot %s bytes (%s local); archive %s bytes (maximum %s)\n' \
            "$scope" "$(tree_bytes "$cache")" "$(tree_bytes "$snapshot")" \
            "$(tree_bytes "$snapshot/local")" "$archive_bytes" "$archive_bytes_max"
        if (( archive_bytes + archive_timestamp_slack_bytes <= archive_bytes_max )); then
            printf 'save=true\n' >> "$output"
            printf 'Compiler cache: save\n'
            return 0
        fi
    done
    printf '::warning::Compiler cache: the snapshot of %s exceeds the lane maximum of %s bytes; save skipped, previous entry kept\n' \
        "$admitted" "$archive_bytes_max"
}

case "${1:-}" in
    track)
        [[ $# -eq 1 ]] || usage
        track
        ;;
    work)
        [[ $# -eq 2 && "${KOSMOS_LANE_DEADLINE:-}" =~ ^[0-9]+$ ]] || usage
        work "$2"
        ;;
    admit)
        [[ $# -eq 3 && "$2" =~ ^[0-9]+$ && "$3" =~ ^(success|failure|cancelled)$ ]] || usage
        admit "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
