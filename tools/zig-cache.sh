#!/usr/bin/env bash
set -euo pipefail

cache=.zig-cache
snapshot=.zig-cache-upload
state=${KOSMOS_CACHE_STATE:-${RUNNER_TEMP:?}/zig-cache-access}
unread_epoch=1

usage() {
    printf 'Usage: bash tools/zig-cache.sh track\n' >&2
    printf '       bash tools/zig-cache.sh admit PHASE ARCHIVE_BYTES_MAX\n' >&2
    exit 64
}

tree_identity() {
    find "$1" -type f ! -path '*/tmp/*' ! -path '*/h/timestamp' -printf '%P\t%s\n' |
        LC_ALL=C sort | sha256sum | cut -d' ' -f1
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
    mkdir -p -- "$state" "$cache/tmp"
    if [[ ! -e "$state/started" ]]; then
        date +%s.%N > "$state/started"
        : > "$state/touched"
        tree_identity "$cache" > "$state/restored"
        access_time_tracking > "$state/tracking"
        printf 'Compiler cache restored: %s bytes; access tracking %s\n' \
            "$(tree_bytes "$cache")" "$(< "$state/tracking")"
    fi
    if [[ "$(< "$state/tracking")" == on ]]; then
        find "$cache" -type f -exec touch -a -d "@$unread_epoch" -- {} +
    fi
}

classify_local_units() {
    awk -F '\t' \
        -v started="$(< "$state/started")" \
        -v tracking="$(< "$state/tracking")" \
        -v unread="$unread_epoch" \
        -v touched_in="$state/touched" \
        -v touched_out="$state/touched.next" \
        -v prune_out="$state/prune" '
        BEGIN {
            while ((getline line < touched_in) > 0) before[line] = 1
            close(touched_in)
            printf "" > touched_out
        }
        {
            atime = $1; mtime = $2; bytes = $3; path = $4
            written = mtime + 0 >= started + 0
            touched = tracking == "on" && (atime + 0 > unread + 0.5 || written || (path in before))
            if (touched) print path > touched_out
            n = split(path, part, "/")
            if (n < 4 || part[1] != "local") next
            kind = part[3]
            if (kind !~ /^(h|o|c|z)$/) next
            if (kind == "h" && part[4] == "timestamp") next
            unit = part[1] "/" part[2] "/" kind "/" part[4]
            unit_root[unit] = part[2]
            unit_kind[unit] = kind
            unit_bytes[unit] += bytes
            if (touched) unit_touched[unit] = 1
            if (written) unit_written[unit] = 1
            roots[part[2]] = 1
        }
        END {
            printf "" > prune_out
            for (unit in unit_root) {
                root = unit_root[unit]
                units[root]++
                if (!(unit in unit_touched) || (unit in unit_written)) continue
                if (unit_kind[unit] == "h") hits[root]++
                if (unit_kind[unit] == "o" || unit_kind[unit] == "c") reads[root]++
            }
            for (root in roots) {
                certified[root] = tracking == "on" && hits[root] + 0 == reads[root] + 0
            }
            for (unit in unit_root) {
                root = unit_root[unit]
                if (!certified[root] || (unit in unit_touched)) continue
                print unit > prune_out
                pruned[root]++
                pruned_bytes[root] += unit_bytes[unit]
            }
            for (root in roots) {
                printf "Compiler cache local/%s: %d units; %d hit manifests; %d read outputs; %s; pruned %d units (%.0f bytes)\n", \
                    root, units[root], hits[root], reads[root], \
                    certified[root] ? "every hit output read" : "pruning withheld", \
                    pruned[root], pruned_bytes[root]
            }
        }
    ' "$state/listing"
}

empty_temporary_directories() {
    local directory
    for directory in "$snapshot/tmp" "$snapshot"/*/tmp "$snapshot"/local/*/tmp; do
        if [[ -d "$directory" ]]; then
            find "$directory" -mindepth 1 -delete
        fi
    done
}

admit() {
    local phase=$1 archive_bytes_max=$2
    local output=${GITHUB_OUTPUT:-/dev/null}
    printf 'save=false\n' >> "$output"
    rm -rf -- "$snapshot"
    if [[ ! -e "$state/started" || ! -d "$cache" ]]; then
        printf 'Compiler cache %s: untracked; save skipped\n' "$phase"
        return 0
    fi
    if [[ -n "$(find "$cache" ! -type d ! -type f -print -quit)" ]]; then
        printf 'Compiler cache %s: nonregular file; save skipped\n' "$phase"
        return 0
    fi
    find "$cache" -type f -printf '%A@\t%T@\t%s\t%P\n' > "$state/listing"
    classify_local_units
    LC_ALL=C sort -u -o "$state/touched" "$state/touched" "$state/touched.next"
    cp -al -- "$cache" "$snapshot"
    while IFS= read -r unit; do
        rm -rf -- "${snapshot:?}/$unit"
    done < "$state/prune"
    empty_temporary_directories
    local cache_bytes snapshot_bytes local_bytes identity
    cache_bytes=$(tree_bytes "$cache")
    snapshot_bytes=$(tree_bytes "$snapshot")
    local_bytes=$(tree_bytes "$snapshot/local")
    identity=$(tree_identity "$snapshot")
    if [[ "$identity" == "$(< "$state/restored")" ]] ||
        [[ -e "$state/saved" && "$identity" == "$(< "$state/saved")" ]]; then
        printf 'Compiler cache %s: snapshot %s bytes equals the restored or saved entry; save skipped\n' \
            "$phase" "$snapshot_bytes"
        return 0
    fi
    local archive_bytes
    archive_bytes=$(tar --posix -cf - -P -C "$PWD" "$snapshot" | zstd -T0 --long=30 -q -c | wc -c)
    printf 'Compiler cache %s: cache %s bytes; snapshot %s bytes (%s local); archive %s bytes (maximum %s)\n' \
        "$phase" "$cache_bytes" "$snapshot_bytes" "$local_bytes" "$archive_bytes" "$archive_bytes_max"
    if (( archive_bytes > archive_bytes_max )); then
        printf 'Compiler cache %s: archive exceeds the lane maximum; save skipped, previous entry kept\n' \
            "$phase"
        return 0
    fi
    printf '%s\n' "$identity" > "$state/saved"
    printf 'save=true\n' >> "$output"
    printf 'Compiler cache %s: save\n' "$phase"
}

case "${1:-}" in
    track)
        [[ $# -eq 1 ]] || usage
        track
        ;;
    admit)
        [[ $# -eq 3 && "$3" =~ ^[0-9]+$ ]] || usage
        admit "$2" "$3"
        ;;
    *)
        usage
        ;;
esac
