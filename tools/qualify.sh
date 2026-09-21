#!/usr/bin/env bash
# Qualify a comparison adapter on the local gzip corpus. Not a project L2 gate.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
MANIFEST="$TOOLS_DIR/corpus.tsv"
DATA_DIR="$ROOT_DIR/data"
LOCAL_DIR="$TOOLS_DIR/.local"
# shellcheck source=tools/invoke.sh
source "$TOOLS_DIR/invoke.sh"
KEEP_TOOL_WORK="${KEEP_TOOL_WORK:-0}"
BLOCKING_FAILS=0
TOOL=""
FILTER_CATEGORY=all
FILTER_CLASSES="sanity small"
WORK=""
REPORT_DIR=""
CHECKS=""
RECEIPT=""
SIZES=""
FORMAT=""
THREADS=""
NTHREADS=""
PEER_VERSION=""
COMPRESS_LEVELS=()
COV_CRC=""
COV_ISIZE=""
COV_CONCAT=""
COV_CAP=""

usage() {
    printf '%s\n' \
        'usage: tools/qualify.sh [TOOL]' \
        '       tools/qualify.sh TOOL CATEGORY [CLASS]' \
        '       tools/qualify.sh --full [TOOL]' \
        '' \
        'tools: names in tools/peers.tsv' \
        'categories: sequencing, ms, generalized' \
        'classes: sanity, small, medium, large' \
        '' \
        'Default classes are sanity and small. Concat, truncate, and footer' \
        'corruption run on sanity only. --full or CLASS=all adds medium and large.' \
        'Writes tools/.local/qualify/TOOL/. Fail closed on blocking checks.' \
        'Plaintext lives in /tmp for one file, then is deleted. Not cached.' \
        'Run matrix is tools/peers.tsv (format, level, threads).' \
        'KEEP_TOOL_WORK=1 keeps /tmp work.'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$1" >&2
        return 1
    }
}

require_linux_x64() {
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
        printf 'error: tools/qualify.sh supports Linux x86_64 only\n' >&2
        return 1
    }
}

cleanup() {
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        case "$WORK" in
            /tmp/z-flate-qualify.*)
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
            printf 'error: qualify is ST-only; %s has threads %s\n' "$TOOL" "$threads" >&2
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

load_coverage() {
    local tool ver fmt _compress _decompress _levels st _mt _stream _bound _window _heap crc isize concat cap _dict _source _decode_mode
    COV_CRC=""
    COV_ISIZE=""
    COV_CONCAT=""
    COV_CAP=""
    while IFS=$'\t' read -r tool ver fmt _compress _decompress _levels st _mt _stream _bound _window _heap crc isize concat cap _dict _source; do
        [[ -z "${tool:-}" || "$tool" == \#* || "$tool" == tool ]] && continue
        if [[ "$tool" == "$TOOL" && "$ver" == "$PEER_VERSION" && "$fmt" == "$FORMAT" ]]; then
            COV_CRC="$crc"
            COV_ISIZE="$isize"
            COV_CONCAT="$concat"
            COV_CAP="$cap"
            return
        fi
    done <"$TOOLS_DIR/coverage.tsv"
    printf 'error: no coverage.tsv row for %s %s %s\n' "$TOOL" "$PEER_VERSION" "$FORMAT" >&2
    return 1
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

record() {
    local category="$1" class="$2" filename="$3" op="$4" check="$5" kind="$6" result="$7" detail="$8"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$category" "$class" "$filename" "$op" "$check" "$kind" "$result" "$detail" >>"$CHECKS"
    printf '%s %s %s %s %s %s\n' \
        "$result" "$kind" "$category/$class/$filename" "$op" "$check" "$detail"
    if [[ "$kind" == blocking && "$result" == fail ]]; then
        BLOCKING_FAILS=$((BLOCKING_FAILS + 1))
    fi
}

status_of() {
    local st=0
    set +e
    "$@" >/dev/null 2>"$WORK/err"
    st=$?
    set -e
    printf '%s' "$st"
}

err_text() {
    tr '\n' ' ' <"$WORK/err" | tr '\t' ' ' | sed 's/[[:space:]]\{1,\}/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

xor_byte() {
    python3 -c 'import pathlib,sys
p=pathlib.Path(sys.argv[1])
b=bytearray(p.read_bytes())
idx=int(sys.argv[2])
if idx<0: idx=len(b)+idx
b[idx]^=0xFF
pathlib.Path(sys.argv[3]).write_bytes(b)
' "$1" "$2" "$3"
}

ensure_plain() {
    local gz="$1" plain="$2"
    local expected actual
    expected="$(gzip -l -- "$gz" | awk 'NR==2{print $2}')"
    gzip -dc -- "$gz" >"$plain"
    actual="$(stat -c '%s' "$plain")"
    if [[ "$actual" != "$expected" ]]; then
        printf 'error: plaintext size %s: got %s expected %s\n' "$plain" "$actual" "$expected" >&2
        return 1
    fi
}

zlib_compress_file() {
    python3 -c 'import pathlib,sys,zlib
pathlib.Path(sys.argv[2]).write_bytes(zlib.compress(pathlib.Path(sys.argv[1]).read_bytes(), int(sys.argv[3])))
' "$1" "$2" "$3"
}

zlib_decompress_file() {
    python3 -c 'import pathlib,sys,zlib
pathlib.Path(sys.argv[2]).write_bytes(zlib.decompress(pathlib.Path(sys.argv[1]).read_bytes()))
' "$1" "$2"
}

make_dictionary_header() {
    python3 -c 'import pathlib,sys
pathlib.Path(sys.argv[1]).write_bytes(bytes((0x78,0x20,0,0,0,1)))
' "$1"
}

make_reference() {
    local level="$1" input="$2" output="$3"
    case "$FORMAT" in
        gzip) gzip -n "-$level" -c -- "$input" >"$output" ;;
        zlib) zlib_compress_file "$input" "$output" "$level" ;;
        *) return 64 ;;
    esac
}

decode_reference() {
    local input="$1" output="$2"
    case "$FORMAT" in
        gzip) gzip -dc -- "$input" >"$output" ;;
        zlib) zlib_decompress_file "$input" "$output" ;;
        *) return 64 ;;
    esac
}

test_reference() {
    local input="$1"
    case "$FORMAT" in
        gzip) gzip -t -- "$input" ;;
        zlib) zlib_decompress_file "$input" "$WORK/reference.out" ;;
        *) return 64 ;;
    esac
}

compress_run() {
    local level="$1" in_path="$2" out_path="$3"
    tool_compress "$level" "$in_path" "$out_path"
}

qualify_empty() {
    local empty="$WORK/empty" gz="$WORK/empty.gz" out="$WORK/empty.out" st level
    : >"$empty"
    if [[ ${#COMPRESS_LEVELS[@]} -eq 0 ]]; then
        make_reference 6 "$empty" "$gz"
        st="$(status_of tool_decompress "$gz" "$out")"
        if [[ "$st" != 0 ]]; then
            record - - empty.gz decompress empty blocking fail "$(err_text)"
        elif ! cmp -s "$empty" "$out"; then
            record - - empty.gz decompress empty blocking fail 'reference empty round trip differs'
        else
            record - - empty.gz decompress empty blocking pass ''
        fi
        rm -f -- "$gz" "$out"
        return
    fi
    for level in "${COMPRESS_LEVELS[@]}"; do
        rm -f -- "$gz" "$out"
        st="$(status_of compress_run "$level" "$empty" "$gz")"
        if [[ "$st" != 0 ]]; then
            record - - empty.gz compress "empty_$level" blocking fail "$(err_text)"
            continue
        fi
        st="$(status_of test_reference "$gz")"
        if [[ "$st" != 0 ]]; then
            record - - empty.gz compress "empty_$level" blocking fail "reference decode status $st $(err_text)"
            continue
        fi
        st="$(status_of tool_decompress "$gz" "$out")"
        if [[ "$st" != 0 ]]; then
            record - - empty.gz decompress "empty_$level" blocking fail "$(err_text)"
            continue
        fi
        if ! cmp -s "$empty" "$out"; then
            record - - empty.gz compress "empty_$level" blocking fail 'round trip bytes differ'
            continue
        fi
        record - - empty.gz compress "empty_$level" blocking pass "$(stat -c '%s' "$gz") bytes"
    done
}

zlib_must_reject() {
    local category="$1" class="$2" filename="$3" check="$4" input="$5" output="$6" st
    st="$(status_of tool_decompress "$input" "$output")"
    if [[ "$st" == 0 ]]; then
        record "$category" "$class" "$filename" decompress "$check" blocking fail 'accepted invalid zlib stream'
    else
        record "$category" "$class" "$filename" decompress "$check" blocking pass "status $st $(err_text)"
    fi
    rm -f -- "$output"
}

qualify_zlib_file() {
    local category="$1" class="$2" filename="$3"
    local input tmp plain reference out trunc tail bad_method bad_check bad_payload bad_adler dictionary st
    local uncomp_bytes corpus_bytes expected_output_bytes
    input="$(data_path "$category" "$class" "$filename")"
    tmp="$WORK/$category/$class"
    mkdir -p "$tmp"
    plain="$tmp/plain"
    reference="$tmp/reference.zlib"
    out="$tmp/tool.plain"
    trunc="$tmp/truncated.zlib"
    tail="$tmp/trailing.zlib"
    bad_method="$tmp/bad-method.zlib"
    bad_check="$tmp/bad-check.zlib"
    bad_payload="$tmp/bad-payload.zlib"
    bad_adler="$tmp/bad-adler.zlib"
    dictionary="$tmp/dictionary.zlib"

    st="$(status_of zlib_decompress_file "$input" "$plain")"
    if [[ "$st" != 0 ]]; then
        record "$category" "$class" "$filename" decompress corpus_test blocking fail "status $st $(err_text)"
        rm -rf -- "$tmp"
        return
    fi
    record "$category" "$class" "$filename" decompress corpus_test blocking pass ''
    make_reference 6 "$plain" "$reference"
    expected_output_bytes="$(stat -c '%s' "$plain")"

    st="$(status_of tool_decompress "$reference" "$out" "$expected_output_bytes")"
    if [[ "$st" != 0 ]]; then
        record "$category" "$class" "$filename" decompress plaintext blocking fail "status $st $(err_text)"
    elif cmp -s "$out" "$plain"; then
        record "$category" "$class" "$filename" decompress plaintext blocking pass "$(stat -c '%s' "$out") bytes"
    else
        record "$category" "$class" "$filename" decompress plaintext blocking fail 'decoded bytes differ from reference plaintext'
    fi
    rm -f -- "$out"

    if [[ "$class" == sanity ]]; then
        set +e
        tool_decompress - "$out" "$expected_output_bytes" <"$reference" >/dev/null 2>"$WORK/err"
        st=$?
        set -e
        if [[ "$st" != 0 ]]; then
            record "$category" "$class" "$filename" decompress stdin blocking fail "status $st $(err_text)"
        elif cmp -s "$out" "$plain"; then
            record "$category" "$class" "$filename" decompress stdin blocking pass ''
        else
            record "$category" "$class" "$filename" decompress stdin blocking fail 'stdin decoded bytes differ from reference plaintext'
        fi
        rm -f -- "$out"

        head -c "$(($(stat -c '%s' "$reference") - 1))" "$reference" >"$trunc"
        zlib_must_reject "$category" "$class" "$filename" truncated "$trunc" "$out"

        cat "$reference" >"$tail"
        printf 'tail' >>"$tail"
        zlib_must_reject "$category" "$class" "$filename" trailing "$tail" "$out"

        xor_byte "$reference" 0 "$bad_method"
        zlib_must_reject "$category" "$class" "$filename" bad_method "$bad_method" "$out"

        xor_byte "$reference" 1 "$bad_check"
        zlib_must_reject "$category" "$class" "$filename" bad_fcheck "$bad_check" "$out"

        xor_byte "$reference" 2 "$bad_payload"
        zlib_must_reject "$category" "$class" "$filename" bad_payload "$bad_payload" "$out"

        xor_byte "$reference" -1 "$bad_adler"
        zlib_must_reject "$category" "$class" "$filename" bad_adler "$bad_adler" "$out"

        make_dictionary_header "$dictionary"
        zlib_must_reject "$category" "$class" "$filename" dictionary "$dictionary" "$out"

        record "$category" "$class" "$filename" decompress bounds skip skip 'adapter CLI has no output cap flag'
    fi

    uncomp_bytes="$(stat -c '%s' "$plain")"
    corpus_bytes="$(stat -c '%s' "$input")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$category" "$class" "$filename" \
        "$FORMAT" "-" "$THREADS" \
        "$uncomp_bytes" "$corpus_bytes" "" "" \
        >>"$SIZES"
    rm -rf -- "$tmp"
}

qualify_file() {
    local category="$1" class="$2" filename="$3"
    if [[ "$FORMAT" == zlib ]]; then
        qualify_zlib_file "$category" "$class" "$filename"
        return
    fi
    local gz plain tmp out trunc concat body crc isize newgz peer_gz st level
    local uncomp_bytes corpus_bytes tool_bytes gzip6_bytes doubled
    gz="$(data_path "$category" "$class" "$filename")"
    tmp="$WORK/$category/$class"
    mkdir -p "$tmp"
    plain="$tmp/plain"
    out="$tmp/tool.plain"
    trunc="$tmp/trunc.gz"
    concat="$tmp/concat.gz"
    body="$tmp/body.gz"
    crc="$tmp/crc.gz"
    isize="$tmp/isize.gz"
    newgz="$tmp/tool.gz"
    peer_gz="$tmp/gzip6.gz"
    doubled="$tmp/plain2"

    st="$(status_of gzip -t -- "$gz")"
    if [[ "$st" != 0 ]]; then
        record "$category" "$class" "$filename" decompress corpus_test blocking fail "gzip -t status $st $(err_text)"
        rm -rf -- "$tmp"
        return
    fi
    record "$category" "$class" "$filename" decompress corpus_test blocking pass ''

    ensure_plain "$gz" "$plain"

    st="$(status_of tool_decompress "$gz" "$out")"
    if [[ "$st" != 0 ]]; then
        record "$category" "$class" "$filename" decompress plaintext blocking fail "status $st $(err_text)"
    elif ! cmp -s "$out" "$plain"; then
        record "$category" "$class" "$filename" decompress plaintext blocking fail 'cmp differs from reference decode'
    else
        record "$category" "$class" "$filename" decompress plaintext blocking pass "$(stat -c '%s' "$out") bytes"
    fi
    rm -f -- "$out"

    if [[ "$class" == sanity ]]; then
        set +e
        tool_decompress - "$out" <"$gz" >/dev/null 2>"$WORK/err"
        st=$?
        set -e
        if [[ "$st" != 0 ]]; then
            record "$category" "$class" "$filename" decompress stdin blocking fail "status $st $(err_text)"
        elif ! cmp -s "$out" "$plain"; then
            record "$category" "$class" "$filename" decompress stdin blocking fail 'cmp differs from reference decode'
        else
            record "$category" "$class" "$filename" decompress stdin blocking pass ''
        fi
        rm -f -- "$out"
    fi

    if [[ "$class" == sanity ]]; then
        cat "$gz" "$gz" >"$concat"
        st="$(status_of tool_decompress "$concat" "$out")"
        cat "$plain" "$plain" >"$doubled"
        if [[ "$COV_CONCAT" == yes ]]; then
            if [[ "$st" != 0 ]]; then
                record "$category" "$class" "$filename" decompress concat blocking fail "status $st $(err_text)"
            elif cmp -s "$out" "$doubled"; then
                record "$category" "$class" "$filename" decompress concat blocking pass ''
            else
                record "$category" "$class" "$filename" decompress concat blocking fail 'output is not concatenated members'
            fi
        else
            if [[ "$st" != 0 ]]; then
                record "$category" "$class" "$filename" decompress concat observed fail "status $st $(err_text)"
            elif cmp -s "$out" "$plain"; then
                record "$category" "$class" "$filename" decompress concat observed gap 'first member only; gzip -dc concatenates'
            else
                record "$category" "$class" "$filename" decompress concat observed fail 'output is not the first member'
            fi
        fi
        rm -f -- "$concat" "$out" "$doubled"

        head -c "$(($(stat -c '%s' "$gz") - 8))" "$gz" >"$trunc"
        st="$(status_of tool_decompress "$trunc" "$out")"
        if [[ "$st" == 0 ]]; then
            record "$category" "$class" "$filename" decompress truncated blocking fail 'exit 0 on truncated gzip'
        else
            record "$category" "$class" "$filename" decompress truncated blocking pass "status $st $(err_text)"
        fi
        rm -f -- "$trunc" "$out"

        xor_byte "$gz" 64 "$body"
        st="$(status_of tool_decompress "$body" "$out")"
        if [[ "$st" == 0 ]]; then
            if cmp -s "$out" "$plain"; then
                record "$category" "$class" "$filename" decompress corrupt_body observed fail 'exit 0 and plaintext unchanged after body flip'
            else
                record "$category" "$class" "$filename" decompress corrupt_body observed gap 'exit 0 with wrong plaintext; no CRC stop'
            fi
        else
            record "$category" "$class" "$filename" decompress corrupt_body observed pass "status $st $(err_text)"
        fi
        rm -f -- "$body" "$out"

        xor_byte "$gz" -8 "$crc"
        st="$(status_of gzip -t -- "$crc")"
        if [[ "$st" == 0 ]]; then
            record "$category" "$class" "$filename" decompress corrupt_crc observed fail 'gzip -t accepted a flipped CRC'
            rm -f -- "$crc"
        else
            st="$(status_of tool_decompress "$crc" "$out")"
            if [[ "$COV_CRC" == yes ]]; then
                if [[ "$st" == 0 ]]; then
                    record "$category" "$class" "$filename" decompress corrupt_crc blocking fail "$TOOL exit 0 on flipped CRC"
                else
                    record "$category" "$class" "$filename" decompress corrupt_crc blocking pass "status $st $(err_text)"
                fi
            else
                if [[ "$st" == 0 ]] && cmp -s "$out" "$plain"; then
                    record "$category" "$class" "$filename" decompress corrupt_crc observed gap "gzip -t rejects; $TOOL writes matching plaintext"
                elif [[ "$st" == 0 ]]; then
                    record "$category" "$class" "$filename" decompress corrupt_crc observed fail "$TOOL exit 0 with wrong plaintext"
                else
                    record "$category" "$class" "$filename" decompress corrupt_crc observed pass "$TOOL status $st $(err_text)"
                fi
            fi
            rm -f -- "$crc" "$out"
        fi

        xor_byte "$gz" -1 "$isize"
        st="$(status_of gzip -t -- "$isize")"
        if [[ "$st" == 0 ]]; then
            record "$category" "$class" "$filename" decompress corrupt_isize observed fail 'gzip -t accepted a flipped ISIZE'
            rm -f -- "$isize"
        else
            st="$(status_of tool_decompress "$isize" "$out")"
            if [[ "$COV_ISIZE" == yes ]]; then
                if [[ "$st" == 0 ]]; then
                    record "$category" "$class" "$filename" decompress corrupt_isize blocking fail "$TOOL exit 0 on flipped ISIZE"
                else
                    record "$category" "$class" "$filename" decompress corrupt_isize blocking pass "status $st $(err_text)"
                fi
            else
                if [[ "$st" == 0 ]] && cmp -s "$out" "$plain"; then
                    record "$category" "$class" "$filename" decompress corrupt_isize observed gap "gzip -t rejects; $TOOL writes matching plaintext"
                elif [[ "$st" == 0 ]]; then
                    record "$category" "$class" "$filename" decompress corrupt_isize observed fail "$TOOL exit 0 with wrong plaintext"
                else
                    record "$category" "$class" "$filename" decompress corrupt_isize observed pass "$TOOL status $st $(err_text)"
                fi
            fi
            rm -f -- "$isize" "$out"
        fi

        if [[ "$COV_CAP" == yes ]]; then
            record "$category" "$class" "$filename" decompress bounds skip skip 'cap claimed; no adapter flag yet'
        else
            record "$category" "$class" "$filename" decompress bounds skip skip 'adapter has no output cap'
        fi
    fi

    gzip -c -6 -- "$plain" >"$peer_gz"
    gzip6_bytes="$(stat -c '%s' "$peer_gz")"
    st="$(status_of tool_decompress "$peer_gz" "$out")"
    if [[ "$st" != 0 ]]; then
        record "$category" "$class" "$filename" compress peer_encode blocking fail "status $st $(err_text)"
    elif ! cmp -s "$out" "$plain"; then
        record "$category" "$class" "$filename" compress peer_encode blocking fail "$TOOL decompress of reference level 6 differs"
    else
        record "$category" "$class" "$filename" compress peer_encode blocking pass "$gzip6_bytes bytes"
    fi
    rm -f -- "$out"

    uncomp_bytes="$(stat -c '%s' "$plain")"
    corpus_bytes="$(stat -c '%s' "$gz")"
    for level in "${COMPRESS_LEVELS[@]}"; do
        rm -f -- "$newgz" "$out"
        st="$(status_of compress_run "$level" "$plain" "$newgz")"
        if [[ "$st" != 0 ]]; then
            record "$category" "$class" "$filename" compress "write_$level" blocking fail "status $st $(err_text)"
            continue
        fi
        tool_bytes="$(stat -c '%s' "$newgz")"
        record "$category" "$class" "$filename" compress "write_$level" blocking pass "$tool_bytes bytes"

        st="$(status_of test_reference "$newgz")"
        if [[ "$st" != 0 ]]; then
            record "$category" "$class" "$filename" compress "integrity_$level" blocking fail "reference decode status $st $(err_text)"
        else
            record "$category" "$class" "$filename" compress "integrity_$level" blocking pass ''
        fi

        decode_reference "$newgz" "$out"
        if ! cmp -s "$out" "$plain"; then
            record "$category" "$class" "$filename" compress "peer_decode_$level" blocking fail "reference decode of $TOOL output differs"
        else
            record "$category" "$class" "$filename" compress "peer_decode_$level" blocking pass ''
        fi
        rm -f -- "$out"

        st="$(status_of tool_decompress "$newgz" "$out")"
        if [[ "$st" != 0 ]]; then
            record "$category" "$class" "$filename" compress "roundtrip_$level" blocking fail "status $st $(err_text)"
        elif ! cmp -s "$out" "$plain"; then
            record "$category" "$class" "$filename" compress "roundtrip_$level" blocking fail "$TOOL decompress of own output differs"
        else
            record "$category" "$class" "$filename" compress "roundtrip_$level" blocking pass ''
        fi
        rm -f -- "$out" "$newgz"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$category" "$class" "$filename" \
            "$FORMAT" "$level" "$THREADS" \
            "$uncomp_bytes" "$corpus_bytes" "$tool_bytes" "$gzip6_bytes" \
            >>"$SIZES"
    done
    if [[ ${#COMPRESS_LEVELS[@]} -eq 0 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$category" "$class" "$filename" \
            "$FORMAT" "-" "$THREADS" \
            "$uncomp_bytes" "$corpus_bytes" 0 "$gzip6_bytes" \
            >>"$SIZES"
    fi
    rm -rf -- "$tmp"
}

write_meta() {
    local cpu
    cpu="$(awk -F: '/^model name/{gsub(/^ /,"",$2); print $2; exit}' /proc/cpuinfo)"
    {
        printf 'schema\tz-flate-qualify-v2\n'
        printf 'tool\t%s\n' "$TOOL"
        printf 'tool_version\t%s\n' "$(tool_version_text)"
        printf 'format\t%s\n' "$FORMAT"
        printf 'decode_mode\t%s\n' "$(tool_decode_mode "$TOOL")"
        printf 'compress_levels\t%s\n' "${COMPRESS_LEVELS[*]}"
        printf 'decompress_level\t-\n'
        printf 'threads\t%s\n' "$THREADS"
        printf 'nthreads\t%s\n' "$NTHREADS"
        printf 'classes\t%s\n' "$FILTER_CLASSES"
        if [[ "$FORMAT" == gzip ]]; then
            printf 'oracle\tgnu-gzip\n'
            printf 'oracle_version\t%s\n' "$(gzip --version | awk 'NR==1{print $2}')"
        else
            printf 'oracle\tsystem-zlib\n'
            printf 'reference_generator\tpython-zlib\n'
            printf 'reference_generator_version\t%s\n' "$(python3 --version 2>&1 | awk '{print $2}')"
        fi
        printf 'host\t%s\n' "$(uname -n)"
        printf 'kernel\t%s\n' "$(uname -srm)"
        printf 'cpu\t%s\n' "$cpu"
        printf 'nproc\t%s\n' "$(nproc)"
        printf 'suite_commit\t%s\n' "$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)"
        if git -C "$ROOT_DIR" rev-parse HEAD >/dev/null 2>&1 &&
            [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
            printf 'suite_dirty\ttrue\n'
        else
            printf 'suite_dirty\tfalse\n'
        fi
    } >"$REPORT_DIR/meta.tsv"
}

write_receipt() {
    {
        printf 'schema\tz-flate-qualify-receipt-v1\n'
        printf 'tool\t%s\n' "$TOOL"
        printf 'classes\t%s\n' "$FILTER_CLASSES"
        printf 'blocking_fails\t%s\n' "$BLOCKING_FAILS"
        if [[ "$BLOCKING_FAILS" -eq 0 ]]; then
            printf 'status\tpass\n'
        else
            printf 'status\tfail\n'
        fi
    } >"$RECEIPT"
}

main() {
    require_linux_x64
    require_command gzip
    require_command python3
    local full=0
    case "${1:-}" in
        --help | -h)
            usage
            return
            ;;
        --full)
            full=1
            shift
            ;;
    esac
    case "${1:-}" in
        '') TOOL=std-gzip ;;
        *)
            TOOL="$(expand_tool "$1")"
            ;;
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

    "$TOOLS_DIR/install.sh" --check "$TOOL"
    load_peer_config
    load_coverage

    local engine
    engine="$(tool_engine)"
    [[ -x "$engine" ]] || {
        printf 'error: missing engine: %s\n' "$engine" >&2
        return 1
    }

    REPORT_DIR="$LOCAL_DIR/qualify/$TOOL"
    mkdir -p "$REPORT_DIR"
    CHECKS="$REPORT_DIR/checks.tsv"
    RECEIPT="$REPORT_DIR/receipt.tsv"
    SIZES="$REPORT_DIR/sizes.tsv"
    printf '%s\n' \
        'category	class	filename	op	check	kind	result	detail' \
        >"$CHECKS"
    printf '%s\n' \
        'category	class	filename	format	level	threads	uncompressed_bytes	corpus_bytes	tool_bytes	peer_gzip6_bytes' \
        >"$SIZES"
    write_meta
    WORK="$(mktemp -d /tmp/z-flate-qualify.XXXXXX)"
    printf 'qualify %s levels: %s classes: %s\n' "$TOOL" "${COMPRESS_LEVELS[*]}" "$FILTER_CLASSES"

    qualify_empty
    local category class filename
    while IFS=$'\t' read -r category class filename; do
        printf 'qualify: %s/%s/%s\n' "$category" "$class" "$filename"
        qualify_file "$category" "$class" "$filename"
    done < <(each_row)

    write_receipt
    if [[ "$BLOCKING_FAILS" -ne 0 ]]; then
        printf 'error: %s blocking check(s) failed; see %s\n' "$BLOCKING_FAILS" "$CHECKS" >&2
        return 1
    fi
    printf 'qualify pass: %s\n' "$RECEIPT"
}

main "$@"
