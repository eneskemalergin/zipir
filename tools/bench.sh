#!/usr/bin/env bash
# Time a qualified comparison adapter with Zebrac. Not a project L3 gate.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
MANIFEST="$TOOLS_DIR/corpus.tsv"
DATA_DIR="$ROOT_DIR/data"
LOCAL_DIR="$TOOLS_DIR/.local"
# shellcheck source=tools/invoke.sh
source "$TOOLS_DIR/invoke.sh"
KEEP_TOOL_WORK="${KEEP_TOOL_WORK:-0}"
FORCE=0
TOOL=""
FILTER_CATEGORY=all
FILTER_CLASSES="sanity small"
WORK=""
FORMAT=""
THREADS=""
NTHREADS=""
PEER_VERSION=""
COMPRESS_LEVELS=()

usage() {
    printf '%s\n' \
        'usage: tools/bench.sh [TOOL]' \
        '       tools/bench.sh TOOL CATEGORY [CLASS]' \
        '       tools/bench.sh --full [TOOL]' \
        '       tools/bench.sh --force [TOOL]' \
        '' \
        'tools: names in tools/peers.tsv' \
        '' \
        'Default classes are sanity and small. --full or CLASS=all adds medium and large.' \
        'Requires a passing tools/qualify.sh receipt for TOOL.' \
        'Writes keyed JSON under tools/.local/zebrac/TOOL/FORMAT/LEVEL/THREADS/.' \
        'Decompress LEVEL is -. Then runs tools/report.sh.' \
        'Prepares plaintext and zlib reference inputs under /tmp when needed, then deletes them.' \
        'Sampling: --warmup 3 --min-samples 25 --max-samples 25. No --allow-failures.' \
        'Skips JSON that already has 25 samples and 0 failures. --force re-times those.'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$1" >&2
        return 1
    }
}

require_linux_x64() {
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
        printf 'error: tools/bench.sh supports Linux x86_64 only\n' >&2
        return 1
    }
}

cleanup() {
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        case "$WORK" in
            /tmp/zipir-bench.*)
                if [[ "$KEEP_TOOL_WORK" == 1 ]]; then
                    printf 'keep: %s\n' "$WORK"
                else
                    rm -rf -- "$WORK"
                fi
                ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

known_tools() {
    local tool ver fmt level threads nthreads
    while IFS=$'\t' read -r tool ver fmt level threads nthreads; do
        [[ -z "${tool:-}" || "$tool" == \#* || "$tool" == tool ]] && continue
        printf '%s\n' "$tool"
    done <"$TOOLS_DIR/peers.tsv" | sort -u
}

expand_tool() {
    local name="$1" candidate
    while IFS= read -r candidate; do
        if [[ "$candidate" == "$name" ]]; then
            printf '%s\n' "$name"
            return
        fi
    done < <(known_tools)
    printf 'error: unknown tool: %s\n' "$name" >&2
    return 64
}

expand_category() {
    case "$1" in
        all) printf '%s\n' all ;;
        sequencing | ms | generalized) printf '%s\n' "$1" ;;
        *)
            printf 'error: unknown category: %s\n' "$1" >&2
            return 64
            ;;
    esac
}

expand_classes() {
    case "$1" in
        all) printf '%s\n' 'sanity small medium large' ;;
        sanity | small | medium | large) printf '%s\n' "$1" ;;
        *)
            printf 'error: unknown class: %s\n' "$1" >&2
            return 64
            ;;
    esac
}

class_selected() {
    local wanted="$1" item
    for item in $FILTER_CLASSES; do
        if [[ "$item" == "$wanted" ]]; then
            return 0
        fi
    done
    return 1
}

load_peer_config() {
    local tool ver fmt level threads nthreads found=0
    COMPRESS_LEVELS=()
    FORMAT=""
    THREADS=""
    NTHREADS=""
    PEER_VERSION=""
    while IFS=$'\t' read -r tool ver fmt level threads nthreads; do
        [[ -z "${tool:-}" || "$tool" == \#* || "$tool" == tool ]] && continue
        if [[ "$tool" != "$TOOL" ]]; then
            continue
        fi
        if [[ "$threads" != ST ]]; then
            printf 'error: bench is ST-only; %s has threads %s\n' "$TOOL" "$threads" >&2
            return 1
        fi
        if [[ "$found" == 1 ]]; then
            [[ "$fmt" == "$FORMAT" && "$threads" == "$THREADS" && "$ver" == "$PEER_VERSION" ]] || {
                printf 'error: mixed format/version/threads for %s\n' "$TOOL" >&2
                return 1
            }
        else
            FORMAT="$fmt"
            THREADS="$threads"
            NTHREADS="$nthreads"
            PEER_VERSION="$ver"
        fi
        if [[ "$level" != - ]]; then
            COMPRESS_LEVELS+=("$level")
        fi
        found=1
    done <"$TOOLS_DIR/peers.tsv"
    if [[ "$found" != 1 ]]; then
        printf 'error: no peers.tsv row for %s\n' "$TOOL" >&2
        return 1
    fi
}

each_row() {
    local category class filename _bytes _sha256 _url
    while IFS=$'\t' read -r category class filename _bytes _sha256 _url; do
        [[ -z "${category:-}" || "$category" == \#* || "$category" == category ]] && continue
        if [[ "$FILTER_CATEGORY" != all && "$category" != "$FILTER_CATEGORY" ]]; then
            continue
        fi
        if ! class_selected "$class"; then
            continue
        fi
        printf '%s\t%s\t%s\n' "$category" "$class" "$filename"
    done <"$MANIFEST"
}

data_path() {
    local filename="$3"
    if [[ "$FORMAT" == zlib ]]; then
        filename="${filename%.gz}.zlib"
    fi
    printf '%s/%s/%s/%s/%s\n' "$DATA_DIR" "$1" "$FORMAT" "$2" "$filename"
}

make_zlib_reference() {
    python3 -c 'import pathlib,sys,zlib
pathlib.Path(sys.argv[2]).write_bytes(zlib.compress(pathlib.Path(sys.argv[1]).read_bytes(), 6))
' "$1" "$2"
}

make_plain() {
    case "$FORMAT" in
        gzip) gzip -dc -- "$1" >"$2" ;;
        zlib)
            python3 -c 'import pathlib,sys,zlib
pathlib.Path(sys.argv[2]).write_bytes(zlib.decompress(pathlib.Path(sys.argv[1]).read_bytes()))
' "$1" "$2"
            ;;
        *) return 64 ;;
    esac
}

json_path() {
    local op="$1" category="$2" class="$3" level="$4"
    printf '%s/%s/%s/%s/%s/%s.%s.%s.json\n' \
        "$LOCAL_DIR/zebrac" "$TOOL" "$FORMAT" "$level" "$THREADS" \
        "$category" "$class" "$op"
}

json_complete() {
    local json="$1"
    [[ "$FORCE" == 1 ]] && return 1
    [[ -f "$json" ]] || return 1
    python3 -c 'import json,sys
p=sys.argv[1]
d=json.load(open(p))
r=d["results"][0]
failed=r.get("failed_sample_count", 0)
n=r.get("sample_count", 0)
raise SystemExit(0 if failed == 0 and n == 25 else 1)
' "$json"
}

run_zebrac() {
    local json="$1" cmd="$2"
    mkdir -p "$(dirname "$json")"
    printf 'zebrac: %s\n' "$cmd"
    zebrac --color never -q -w 3 -i 25 -a 25 --json "$json" -- "$cmd"
    python3 -c 'import json,sys
p=sys.argv[1]
d=json.load(open(p))
r=d["results"][0]
failed=r.get("failed_sample_count", 0)
n=r.get("sample_count", 0)
if failed:
    sys.exit("error: %s failed_sample_count=%s" % (p, failed))
if n != 25:
    sys.exit("error: %s sample_count=%s want 25" % (p, n))
print("ok: %s samples=%s wall_median_ns=%s rss_median=%s" % (
    p, n, r["wall_time"]["median"], r["peak_rss"]["median"]))
' "$json"
}

run_zebrac_if_needed() {
    local json="$1" cmd="$2"
    if json_complete "$json"; then
        printf 'skip: %s\n' "$json"
        return
    fi
    run_zebrac "$json" "$cmd"
}

main() {
    require_linux_x64
    require_command zebrac
    require_command python3
    require_command gzip
    local full=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help | -h)
                usage
                return
                ;;
            --full)
                full=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                usage >&2
                return 64
                ;;
            *)
                break
                ;;
        esac
    done
    case "${1:-}" in
        '') TOOL=std-gzip ;;
        *) TOOL="$(expand_tool "$1")" ;;
    esac
    if [[ $# -ge 2 ]]; then
        FILTER_CATEGORY="$(expand_category "$2")"
        [[ $# -le 3 ]] || {
            usage >&2
            return 64
        }
        if [[ "$full" == 1 && $# -eq 3 ]]; then
            printf 'error: --full does not take CLASS; omit CLASS or drop --full\n' >&2
            return 64
        fi
        if [[ $# -eq 3 ]]; then
            FILTER_CLASSES="$(expand_classes "$3")"
        fi
    else
        [[ $# -le 1 ]] || {
            usage >&2
            return 64
        }
    fi
    if [[ "$full" == 1 ]]; then
        FILTER_CLASSES="$(expand_classes all)"
    fi

    load_peer_config

    local receipt="$LOCAL_DIR/qualify/$TOOL/receipt.tsv"
    [[ -f "$receipt" ]] || {
        printf 'error: missing qualify receipt: %s\n' "$receipt" >&2
        return 1
    }
    grep -Fqx $'status\tpass' "$receipt" || {
        printf 'error: qualify did not pass; not starting Zebrac\n' >&2
        return 1
    }
    [[ "$(zebrac --help 2>&1 | awk 'NR==1{print $2}')" == 0.6.2 ]] || {
        printf 'error: bench requires zebrac 0.6.2\n' >&2
        return 1
    }

    local engine
    engine="$(tool_engine)"
    [[ -x "$engine" ]] || {
        printf 'error: missing engine: %s\n' "$engine" >&2
        return 1
    }

    local zdir="$LOCAL_DIR/zebrac/$TOOL"
    mkdir -p "$zdir"
    {
        printf 'schema\tzipir-zebrac-v2\n'
        printf 'tool\t%s\n' "$TOOL"
        printf 'tool_version\t%s\n' "$PEER_VERSION"
        printf 'format\t%s\n' "$FORMAT"
        printf 'decode_mode\t%s\n' "$(tool_decode_mode "$TOOL")"
        printf 'compress_levels\t%s\n' "${COMPRESS_LEVELS[*]}"
        printf 'decompress_level\t-\n'
        printf 'threads\t%s\n' "$THREADS"
        printf 'nthreads\t%s\n' "$NTHREADS"
        printf 'zebrac\t0.6.2\n'
        printf 'classes\t%s\n' "$FILTER_CLASSES"
        printf 'warmup\t3\n'
        printf 'min_samples\t25\n'
        printf 'max_samples\t25\n'
        printf 'allow_failures\tfalse\n'
        cat "$LOCAL_DIR/qualify/$TOOL/meta.tsv"
    } >"$zdir/meta.tsv"

    printf 'bench %s format=%s levels=%s threads=%s classes: %s\n' \
        "$TOOL" "$FORMAT" "${COMPRESS_LEVELS[*]}" "$THREADS" "$FILTER_CLASSES"
    WORK="$(mktemp -d /tmp/zipir-bench.XXXXXX)"
    local category class filename input plain reference json level need_plain need_decomp
    while IFS=$'\t' read -r category class filename; do
        input="$(data_path "$category" "$class" "$filename")"
        plain="$WORK/plain"
        reference="$WORK/reference.zlib"

        need_plain=0
        need_decomp=0
        json="$(json_path decompress "$category" "$class" -)"
        json_complete "$json" || need_decomp=1
        for level in "${COMPRESS_LEVELS[@]}"; do
            json="$(json_path compress "$category" "$class" "$level")"
            json_complete "$json" || need_plain=1
        done
        if [[ "$FORMAT" == zlib && "$need_decomp" == 1 ]]; then
            need_plain=1
        fi
        if [[ "$need_plain" == 0 && "$need_decomp" == 0 ]]; then
            printf 'skip file: %s (complete)\n' "$filename"
            continue
        fi
        if [[ "$need_plain" == 1 ]]; then
            make_plain "$input" "$plain"
        fi
        if [[ "$FORMAT" == zlib && "$need_decomp" == 1 ]]; then
            make_zlib_reference "$plain" "$reference"
        fi
        json="$(json_path decompress "$category" "$class" -)"
        if [[ "$need_decomp" == 1 ]]; then
            if [[ "$FORMAT" == zlib ]]; then
                run_zebrac "$json" "$(zebrac_decompress_cmd "$reference" "$(stat -c '%s' "$plain")")"
            else
                run_zebrac "$json" "$(zebrac_decompress_cmd "$input")"
            fi
        else
            printf 'skip: %s\n' "$json"
        fi
        for level in "${COMPRESS_LEVELS[@]}"; do
            json="$(json_path compress "$category" "$class" "$level")"
            run_zebrac_if_needed "$json" "$(zebrac_compress_cmd "$level" "$plain")"
        done
        rm -f -- "$plain"
    done < <(each_row)

    "$TOOLS_DIR/report.sh"
    printf 'bench pass: %s\n' "$zdir"
}

main "$@"
