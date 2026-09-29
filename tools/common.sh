#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# Shared by install.sh, corpus.sh, qualify.sh, and bench.sh: paths, pinned versions, the peer
# table, peer and level selection, corpus rows, and the one place that knows each tool's command
# line. Sourcing it loads and validates tools/peers.tsv.

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
DATA_DIR="$ROOT_DIR/data"
LOCAL_DIR="$TOOLS_DIR/.local"
INSTALLS_DIR="$LOCAL_DIR/installs"
BIN_DIR="$TOOLS_DIR/bin"
MANIFEST="$TOOLS_DIR/corpus.tsv"
PEERS_TSV="$TOOLS_DIR/peers.tsv"
KEEP_TOOL_WORK="${KEEP_TOOL_WORK:-0}"
PEER_SET="${PEER_SET:-prime}"
LEVEL_SET="${LEVEL_SET:-lanes}"
CATEGORY=all
CLASSES="sanity small"
WORK=""

# ---- pinned versions: exact, never a moving branch ----

ZIG_VERSION=0.16.0
STD_GZIP_VERSION=0.16.0
STD_ZLIB_VERSION=0.16.0
# The zipir adapters report the package version.
ZIPIR_VERSION=$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' "$ROOT_DIR/build.zig.zon")
GNU_GZIP_VERSION=1.14
GNU_GZIP_BIN=/usr/bin/gzip
PIGZ_VERSION=2.8
PIGZ_BIN=/usr/bin/pigz
LIBDEFLATE_VERSION=1.26
LIBDEFLATE_URL=https://github.com/ebiggers/libdeflate/archive/refs/tags/v1.26.tar.gz
LIBDEFLATE_SHA256=bba03fffc5538576213675ce6968fcff6ce2e67d82e4d5febea2d05f9f13cf85
ISAL_VERSION=2.32.1
ISAL_URL=https://github.com/intel/isa-l/archive/refs/tags/v2.32.1.tar.gz
ISAL_SHA256=d9f7179ab0e14a3db9b610fac22793854a1435e8423ec9ce07f4cbedc5f92f5e
FLATE2_MINIZ_VERSION=1.1.10
FLATE2_ZLIB_RS_VERSION=1.1.10
ZLIB_RS_VERSION=0.6.7
ZLIB_NG_VERSION=2.3.3
ZLIB_NG_URL=https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.3.3.tar.gz
ZLIB_NG_SHA256=f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1
SYSTEM_ZLIB_VERSION=1.3.1.zlib-ng
HTSLIB_VERSION=1.24
HTSLIB_URL=https://github.com/samtools/htslib/releases/download/1.24/htslib-1.24.tar.bz2
HTSLIB_SHA256=28a8de191381c7a97a35675ceac76fa1ea95e7b678d6a2e9d600a7874e4077de

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    exit 64
}

require_command() {
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 || die "required command not found: $name"
    done
}

require_linux_x64() {
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || die "${0##*/} supports Linux x86_64 only"
}

# Scratch space under /tmp. On exit its top-level files are removed one by one and the directory
# is removed only if that leaves it empty; nothing is deleted recursively, so build trees stay in
# /tmp (cleared at restart) and their path is printed. KEEP_TOOL_WORK=1 keeps everything. A script
# may define cleanup_extra for its own state.
make_work() {
    [[ -n "$WORK" ]] || WORK="$(mktemp -d "/tmp/zipir-$1.XXXXXX")"
}

on_exit() {
    if declare -F cleanup_extra >/dev/null; then cleanup_extra; fi
    if [[ -n "$WORK" && -d "$WORK" && "$WORK" == /tmp/zipir-* ]]; then
        if [[ "$KEEP_TOOL_WORK" == 1 ]]; then
            printf 'keep: %s\n' "$WORK"
        else
            local file
            for file in "$WORK"/* "$WORK"/.[!.]*; do
                if [[ -f "$file" && ! -L "$file" ]]; then rm -f -- "$file"; fi
            done
            rmdir -- "$WORK" 2>/dev/null || printf 'left: %s\n' "$WORK" >&2
        fi
    fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

version_for() {
    case "$1" in
        std-gzip) printf '%s\n' "$STD_GZIP_VERSION" ;;
        std-zlib) printf '%s\n' "$STD_ZLIB_VERSION" ;;
        zipir-*) printf '%s\n' "$ZIPIR_VERSION" ;;
        system-zlib | system-deflate) printf '%s\n' "$SYSTEM_ZLIB_VERSION" ;;
        libdeflate-gzip | libdeflate-zlib | libdeflate-deflate) printf '%s\n' "$LIBDEFLATE_VERSION" ;;
        gnu-gzip) printf '%s\n' "$GNU_GZIP_VERSION" ;;
        pigz) printf '%s\n' "$PIGZ_VERSION" ;;
        igzip) printf '%s\n' "$ISAL_VERSION" ;;
        flate2-miniz) printf '%s\n' "$FLATE2_MINIZ_VERSION" ;;
        flate2-zlib-rs) printf '%s\n' "$FLATE2_ZLIB_RS_VERSION" ;;
        zlib-ng | zlib-ng-zlib | zlib-ng-deflate) printf '%s\n' "$ZLIB_NG_VERSION" ;;
        bgzip | bgzip-libdeflate | bgzip-zlib-ng) printf '%s\n' "$HTSLIB_VERSION" ;;
        *) usage_error "unknown tool: $1" ;;
    esac
}

git_state() {
    local commit dirty=false
    commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)"
    [[ -z "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]] || dirty=true
    printf 'commit\t%s\ndirty\t%s\n' "$commit" "$dirty"
}

host_state() {
    printf 'host\t%s\nkernel\t%s\ncpu\t%s\nnproc\t%s\n' "$(uname -n)" "$(uname -srm)" \
        "$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)" "$(nproc)"
}

# ---- peer table ----

PEER_TOOLS=()
declare -A P_FORMAT=() P_TIER=() P_LEVELS=() P_FAST=() P_BALANCED=() P_DENSE=() P_DECODE=() P_CRC=() P_ISIZE=() P_CONCAT=()

expand_levels() {
    local part level list=()
    for part in $1; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((level = BASH_REMATCH[1]; level <= BASH_REMATCH[2]; level++)); do list+=("$level"); done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            list+=("$part")
        else
            return 1
        fi
    done
    printf '%s\n' "${list[*]}"
}

load_peers() {
    local tool format tier levels fast balanced dense decode crc isize concat extra lane
    while IFS=$'\t' read -r tool format tier levels fast balanced dense decode crc isize concat extra; do
        [[ -z "${tool:-}" || "$tool" == \#* || "$tool" == tool ]] && continue
        [[ -n "${concat:-}" && -z "${extra:-}" ]] || die "peers.tsv: $tool needs 11 columns"
        [[ -z "${P_FORMAT[$tool]:-}" ]] || die "peers.tsv: duplicate row for $tool"
        [[ "$format" =~ ^(gzip|zlib|deflate|bgzf)$ ]] || die "peers.tsv: $tool format must be gzip, zlib, deflate, or bgzf"
        [[ "$tier" =~ ^(prime|extended|all)$ ]] || die "peers.tsv: $tool tier must be prime, extended, or all"
        [[ "$decode" =~ ^(streaming|full-buffer)$ ]] || die "peers.tsv: $tool decode must be streaming or full-buffer"
        if [[ "$levels" == - ]]; then
            [[ "$fast$balanced$dense" == --- ]] || die "peers.tsv: decode-only $tool needs - lanes"
        else
            levels="$(expand_levels "$levels")" || die "peers.tsv: bad levels for $tool"
            for lane in "$fast" "$balanced" "$dense"; do
                [[ " $levels " == *" $lane "* ]] || die "peers.tsv: $tool lane level $lane is not in its levels"
            done
        fi
        PEER_TOOLS+=("$tool")
        P_FORMAT[$tool]="$format" P_TIER[$tool]="$tier" P_LEVELS[$tool]="$levels" P_DECODE[$tool]="$decode"
        P_FAST[$tool]="$fast" P_BALANCED[$tool]="$balanced" P_DENSE[$tool]="$dense"
        if [[ "$format" == gzip ]]; then
            [[ "$crc $isize $concat" =~ ^(yes|no|hint)\ (yes|no|hint)\ (yes|no|hint)$ ]] ||
                die "peers.tsv: $tool crc, isize, and concat must be yes, no, or hint"
        else
            [[ "$crc$isize$concat" == --- ]] || die "peers.tsv: $format tool $tool needs - for crc, isize, and concat"
        fi
        P_CRC[$tool]="$crc" P_ISIZE[$tool]="$isize" P_CONCAT[$tool]="$concat"
    done <"$PEERS_TSV"
    [[ ${#PEER_TOOLS[@]} -gt 0 ]] || die "peers.tsv has no rows"
}
load_peers

expand_tool() {
    [[ -n "${P_FORMAT[$1]:-}" ]] || usage_error "unknown tool: $1 (see tools/peers.tsv)"
    printf '%s\n' "$1"
}

# ---- selection ----

check_selection() {
    [[ "$PEER_SET" =~ ^(prime|extended|all)$ ]] || usage_error "--peers must be prime, extended, or all (got $PEER_SET)"
    [[ "$LEVEL_SET" =~ ^(lanes|all)$ ]] || usage_error "--levels must be lanes or all (got $LEVEL_SET)"
}

tier_selected() {
    case "$PEER_SET:$1" in
        prime:prime | extended:prime | extended:extended | all:*) return 0 ;;
        *) return 1 ;;
    esac
}

selected_tools() {
    local tool
    for tool in "${PEER_TOOLS[@]}"; do
        if tier_selected "${P_TIER[$tool]}"; then printf '%s\n' "$tool"; fi
    done
}

# Compression levels of TOOL for LEVEL_SET, lanes in fast, balanced, dense order; empty if decode-only.
tool_levels() {
    local tool="$1"
    [[ "${P_LEVELS[$tool]}" != - ]] || return 0
    if [[ "$LEVEL_SET" == all ]]; then
        printf '%s\n' "${P_LEVELS[$tool]}"
    else
        printf '%s\n' "${P_FAST[$tool]} ${P_BALANCED[$tool]} ${P_DENSE[$tool]}" | tr ' ' '\n' | awk '!seen[$0]++' | paste -sd' '
    fi
}

lane_of() {
    local tool="$1" level="$2"
    if [[ "$level" == - ]]; then
        printf -- '-\n'
    elif [[ "$level" == "${P_FAST[$tool]}" ]]; then
        printf 'fast\n'
    elif [[ "$level" == "${P_BALANCED[$tool]}" ]]; then
        printf 'balanced\n'
    elif [[ "$level" == "${P_DENSE[$tool]}" ]]; then
        printf 'dense\n'
    else
        printf -- '-\n'
    fi
}

expand_category() {
    [[ "$1" =~ ^(all|sequencing|ms|generalized)$ ]] || usage_error "unknown category: $1"
    printf '%s\n' "$1"
}

# One class, a comma list (sanity,small,medium), or all.
expand_classes() {
    local class list=()
    [[ "$1" != all ]] || set -- sanity,small,medium,large
    for class in ${1//,/ }; do
        [[ "$class" =~ ^(sanity|small|medium|large)$ ]] || usage_error "unknown class: $class"
        [[ " ${list[*]} " == *" $class "* ]] || list+=("$class")
    done
    [[ ${#list[@]} -gt 0 ]] || usage_error "--class needs a value"
    printf '%s\n' "${list[*]}"
}

# Options shared by qualify.sh and bench.sh. Sets PEER_SET, LEVEL_SET, CATEGORY, CLASSES, LIST,
# FORCE, and NAMED (tools given on the command line). --force is accepted when ALLOW_FORCE=1.
parse_run_args() {
    local class=""
    LIST=0 FORCE=0 NAMED=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h | --help)
                usage
                exit 0
                ;;
            --peers | --levels | --category | --class)
                [[ $# -ge 2 ]] || usage_error "$1 needs a value"
                case "$1" in
                    --peers) PEER_SET="$2" ;;
                    --levels) LEVEL_SET="$2" ;;
                    --category) CATEGORY="$(expand_category "$2")" ;;
                    --class) class="$(expand_classes "$2")" ;;
                esac
                shift 2
                continue
                ;;
            --full) class="$(expand_classes all)" ;;
            --list) LIST=1 ;;
            --force)
                [[ "${ALLOW_FORCE:-0}" == 1 ]] || usage_error "unknown option: $1"
                FORCE=1
                ;;
            -*) usage_error "unknown option: $1" ;;
            *) NAMED+=("$(expand_tool "$1")") ;;
        esac
        shift
    done
    [[ -z "$class" ]] || CLASSES="$class"
    check_selection
}

# Tools to run: the named ones, or the selected peer set.
run_tools() {
    if [[ ${#NAMED[@]} -gt 0 ]]; then printf '%s\n' "${NAMED[@]}"; else selected_tools; fi
}

# ---- corpus ----

# category class filename of every corpus row of FORMAT in CATEGORY and CLASSES.
corpus_rows() {
    awk -F'\t' -v format="$1" -v category="$CATEGORY" -v classes=" $CLASSES " '
        /^#/ || $1 == "category" || NF == 0 { next }
        $3 == format && (category == "all" || $1 == category) && index(classes, " " $2 " ") {
            print $1 "\t" $2 "\t" $4
        }' "$MANIFEST"
}

data_path() {
    printf '%s/%s/%s/%s/%s\n' "$DATA_DIR" "$1" "$2" "$3" "$4"
}

# Independent zlib decoder (Python zlib); rejects truncated streams and trailing data.
zlib_decode() {
    python3 - "$1" "$2" <<'PY'
import sys, zlib
d = zlib.decompressobj()
with open(sys.argv[1], "rb") as src, open(sys.argv[2], "wb") as out:
    while chunk := src.read(1 << 20):
        out.write(d.decompress(chunk))
    out.write(d.flush())
if not d.eof or d.unused_data:
    sys.exit(f"{sys.argv[1]}: incomplete zlib stream or trailing data")
PY
}

# Independent raw DEFLATE decoder (Python zlib, windowBits -15); rejects an unfinished final
# block and trailing data.
deflate_decode() {
    python3 - "$1" "$2" <<'PY'
import sys, zlib
d = zlib.decompressobj(-15)
with open(sys.argv[1], "rb") as src, open(sys.argv[2], "wb") as out:
    while chunk := src.read(1 << 20):
        out.write(d.decompress(chunk))
    out.write(d.flush())
if not d.eof or d.unused_data:
    sys.exit(f"{sys.argv[1]}: incomplete raw DEFLATE stream or trailing data")
PY
}

# Independent BGZF structure check (no zipir code). With a gzip source path, also
# compares every decoded byte with that source's plaintext.
verify_bgzf_file() {
    python3 - "$1" "${2:-}" <<'PY'
import gzip
import struct
import sys
import zlib

EOF_MARKER = bytes.fromhex("1f8b08040000000000ff0600424302001b0003000000000000000000")


def fail(message):
    raise SystemExit(f"{sys.argv[1]}: {message}")


path, source = sys.argv[1], sys.argv[2]
expected = gzip.open(source, "rb") if source else None
blocks = 0
last = b""
with open(path, "rb") as stream:
    while True:
        offset = stream.tell()
        header = stream.read(12)
        if not header:
            break
        if len(header) < 12 or header[:4] != b"\x1f\x8b\x08\x04":
            fail(f"not a BGZF block at offset {offset}")
        xlen = struct.unpack_from("<H", header, 10)[0]
        extra = stream.read(xlen)
        if len(extra) != xlen:
            fail(f"truncated extra field at offset {offset}")
        bsize = None
        at = 0
        while at + 4 <= xlen:
            si, length = extra[at:at + 2], struct.unpack_from("<H", extra, at + 2)[0]
            if at + 4 + length > xlen:
                fail(f"subfield overruns XLEN at offset {offset}")
            if si == b"BC" and length == 2:
                bsize = struct.unpack_from("<H", extra, at + 4)[0]
            at += 4 + length
        if at != xlen:
            fail(f"partial subfield in extra field at offset {offset}")
        if bsize is None:
            fail(f"no BC subfield at offset {offset}")
        rest = stream.read(bsize + 1 - 12 - xlen)
        if len(rest) != bsize + 1 - 12 - xlen or len(rest) < 8:
            fail(f"truncated block at offset {offset}")
        inflater = zlib.decompressobj(-15)
        data = inflater.decompress(rest[:-8])
        if not inflater.eof or inflater.unused_data:
            fail(f"DEFLATE stream does not end at BSIZE at offset {offset}")
        crc, isize = struct.unpack_from("<II", rest, len(rest) - 8)
        if zlib.crc32(data) != crc or len(data) != isize or isize > 65536:
            fail(f"CRC32 or ISIZE mismatch at offset {offset}")
        if expected is not None and expected.read(len(data)) != data:
            fail(f"decoded bytes differ from {source} in block at offset {offset}")
        last = header + extra + rest
        blocks += 1
if blocks == 0 or last != EOF_MARKER:
    fail("missing BGZF EOF marker")
if expected is not None and expected.read(1):
    fail(f"shorter than {source}")
PY
}

# Formats timed and qualified, in report order.
FORMATS=(gzip zlib deflate bgzf)

# Reference plaintext of a file in FORMAT. BGZF is gzip members, so GNU gzip reads it.
plain_of() {
    case "$1" in
        gzip | bgzf) gzip -dc -- "$2" >"$3" ;;
        zlib) zlib_decode "$2" "$3" ;;
        deflate) deflate_decode "$2" "$3" ;;
        *) die "no reference decoder for $1" ;;
    esac
}

# Reference check of a compressor's output in FORMAT: BGZF structure first, then the reference
# decoder, then a byte comparison with PLAIN. Uses $WORK/ref.
reference_matches() {
    local format="$1" encoded="$2" plain="$3"
    if [[ "$format" == bgzf ]]; then verify_bgzf_file "$encoded" "" >&2 || return 1; fi
    plain_of "$format" "$encoded" "$WORK/ref" && cmp -s "$WORK/ref" "$plain"
}

# Prints the planned matrix for the tools on stdin and its size.
list_selection() {
    local tool level rows=0 files
    printf '%-16s %-6s %-6s %s\n' tool format level lane
    while IFS= read -r tool; do
        printf '%-16s %-6s %-6s %s\n' "$tool" "${P_FORMAT[$tool]}" - -
        rows=$((rows + 1))
        for level in $(tool_levels "$tool"); do
            printf '%-16s %-6s %-6s %s\n' "$tool" "${P_FORMAT[$tool]}" "$level" "$(lane_of "$tool" "$level")"
            rows=$((rows + 1))
        done
    done
    files="$(for f in "${FORMATS[@]}"; do printf '%s %s files; ' "$f" "$(corpus_rows "$f" | wc -l)"; done)"
    printf 'selection: --peers %s --levels %s, %s rows; classes: %s; category: %s; corpus: %s\n' \
        "$PEER_SET" "$LEVEL_SET" "$rows" "$CLASSES" "$CATEGORY" "$files"
}

# ---- tool command lines ----

tool_path() {
    case "$1" in
        gnu-gzip) printf '%s\n' "$GNU_GZIP_BIN" ;;
        pigz) printf '%s\n' "$PIGZ_BIN" ;;
        *) printf '%s\n' "$BIN_DIR/$1" ;;
    esac
}

# Binary identity without a digest: resolved path, size, and mtime.
tool_identity() {
    local path
    path="$(readlink -f "$(tool_path "$1")")"
    printf '%s %s %s\n' "$path" "$(stat -c '%s' "$path")" "$(stat -c '%Y' "$path")"
}

tool_version_text() {
    local path
    path="$(tool_path "$1")"
    case "$1" in
        gnu-gzip) "$path" --version | awk 'NR==1{print $2}' ;;
        pigz) "$path" --version | awk '{print $2; exit}' ;;
        libdeflate-gzip) "$path" -V | awk 'NR==1{v=$NF; sub(/^v/, "", v); print v}' ;;
        igzip | zlib-ng) version_for "$1" ;;
        bgzip-*) "$path" --version | awk 'NR==1{print $3}' ;;
        *) "$path" --version | awk '{print $2}' ;;
    esac
}

# Sets CMD to the argv of TOOL doing OP (compress or decompress) at LEVEL on IN (- is stdin).
# CMD_STDOUT=1 when the tool writes to stdout; otherwise the output path follows CMD.
# EXPECTED is the plaintext size, passed only to the libdeflate adapters (full-buffer decode).
tool_cmd() {
    local tool="$1" op="$2" level="$3" in="$4" expected="${5:-}" bin file=()
    bin="$(tool_path "$tool")"
    [[ "$in" == - ]] || file=("$in")
    [[ "$op" == decompress || "${P_LEVELS[$tool]}" != - ]] || die "$tool is decode-only"
    CMD_STDOUT=1
    case "$tool:$op" in
        gnu-gzip:compress) CMD=("$bin" -n "-$level" -c -- "${file[@]}") ;;
        gnu-gzip:decompress) CMD=("$bin" -d -c -- "${file[@]}") ;;
        pigz:compress) CMD=("$bin" -p1 -n "-$level" -c -- "${file[@]}") ;;
        pigz:decompress) CMD=("$bin" -p1 -d -c -- "${file[@]}") ;;
        libdeflate-gzip:compress) CMD=("$bin" "-$level" -k -c "${file[@]}") ;;
        libdeflate-gzip:decompress) CMD=("$bin" -d -k -c "${file[@]}") ;;
        igzip:compress) CMD=("$bin" -n "-$level" -c "${file[@]}") ;;
        zlib-ng:compress) CMD=("$bin" "-$level" -c "${file[@]}") ;;
        igzip:decompress | zlib-ng:decompress) CMD=("$bin" -d -c "${file[@]}") ;;
        # One thread; bgzip reads stdin when no file is named. Text is split at lines by default.
        bgzip-*:compress) CMD=("$bin" -@1 -l "$level" -c "${file[@]}") ;;
        bgzip-*:decompress) CMD=("$bin" -@1 -d -c "${file[@]}") ;;
        libdeflate-zlib:decompress | libdeflate-deflate:decompress)
            CMD_STDOUT=0
            CMD=("$bin" decompress)
            [[ -z "$expected" ]] || CMD+=(--expected-output-bytes "$expected")
            CMD+=("$in")
            ;;
        *:compress) CMD_STDOUT=0 CMD=("$bin" compress --level "$level" "$in") ;;
        *:decompress) CMD_STDOUT=0 CMD=("$bin" decompress "$in") ;;
    esac
}

# tool_run TOOL OP LEVEL IN OUT [EXPECTED]
tool_run() {
    tool_cmd "$1" "$2" "$3" "$4" "${6:-}"
    if [[ "$CMD_STDOUT" == 1 ]]; then "${CMD[@]}" >"$5"; else "${CMD[@]}" "$5"; fi
}

# One Zebrac command string (Zebrac splits it without a shell and discards stdout).
zebrac_cmd() {
    local arg
    tool_cmd "$@"
    [[ "$CMD_STDOUT" == 1 ]] || CMD+=(/dev/null)
    for arg in "${CMD[@]}"; do
        [[ "$arg" != *[[:space:]]* ]] || die "Zebrac cannot take a path with spaces: $arg"
    done
    printf '%s\n' "${CMD[*]}"
}

# Qualify receipt value for TOOL and KEY.
receipt_value() {
    awk -F'\t' -v key="$2" '$1 == key { print $2 }' "$LOCAL_DIR/qualify/$1/receipt.tsv" 2>/dev/null
}

# A tool may be timed only when its qualify receipt passed on the current binary and covers LEVELS.
require_qualified() {
    local tool="$1" level class
    shift
    [[ "$(receipt_value "$tool" schema)" == zipir-qualify-v3 ]] || die "$tool has no current qualify receipt; run tools/qualify.sh $tool"
    [[ "$(receipt_value "$tool" status)" == pass ]] || die "$tool failed qualify; see $LOCAL_DIR/qualify/$tool/checks.tsv"
    [[ "$(receipt_value "$tool" binary)" == "$(tool_identity "$tool")" ]] ||
        die "$tool binary changed since qualify; run tools/qualify.sh $tool"
    for level in "$@"; do
        [[ " $(receipt_value "$tool" levels) " == *" $level "* ]] ||
            die "$tool level $level was not qualified; run tools/qualify.sh --levels $LEVEL_SET $tool"
    done
    # The receipt must cover every file that will be timed.
    for class in $CLASSES; do
        [[ " $(receipt_value "$tool" classes) " == *" $class "* ]] ||
            die "$tool was not qualified on $class files; run tools/qualify.sh --class $class $tool (or --full)"
    done
    [[ "$(receipt_value "$tool" category)" =~ ^(all|$CATEGORY)$ ]] ||
        die "$tool was qualified on $(receipt_value "$tool" category) files only; run tools/qualify.sh $tool"
}
