#!/usr/bin/env bash
# Check comparison peers against independent references (GNU gzip, Python zlib) on the local
# corpus before they are timed. Writes tools/.local/qualify/TOOL/{checks,receipt}.tsv.
# Not a project L2 gate.

set -euo pipefail
# shellcheck source=tools/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
    printf '%s\n' \
        'usage: tools/qualify.sh [--peers SET] [--levels SET] [--category C] [--class C | --full] [--list] [TOOL...]' \
        '' \
        'Without TOOL, qualifies every tool in the selected peer set; a named tool runs whatever its tier.' \
        '--peers prime|extended|all   peer tiers from tools/peers.tsv (default prime)' \
        '--levels lanes|all           fast/balanced/dense lanes or every level (default lanes)' \
        '--category sequencing|ms|generalized, --class sanity|small|medium|large|all' \
        '--full                       every class (default classes are sanity and small)' \
        '--list                       print the planned matrix and corpus size; run nothing' \
        '' \
        'Stdin, concatenation, truncation, and corruption checks run on sanity files only.' \
        'Blocking failures fail the tool. KEEP_TOOL_WORK=1 keeps the /tmp work directory.'
}

TOOL="" LEVELS="" CHECKS="" CAT="" CLS="" FILE="" ST=0 ERR="" BLOCKING_FAILS=0

rec() {
    local op="$1" check="$2" kind="$3" result="$4" detail="$5"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$CAT" "$CLS" "$FILE" "$op" "$check" "$kind" "$result" "$detail" >>"$CHECKS"
    printf '%s %s %s %s %s %s\n' "$result" "$kind" "$CAT/$CLS/$FILE" "$op" "$check" "$detail"
    if [[ "$kind" == blocking && "$result" == fail ]]; then BLOCKING_FAILS=$((BLOCKING_FAILS + 1)); fi
}

# Runs a command; sets ST and a one-line ERR from its stderr.
attempt() {
    set +e
    "$@" >/dev/null 2>"$WORK/err"
    ST=$?
    set -e
    ERR="$(tr '\n\t' '  ' <"$WORK/err" | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')"
}

dec() { tool_run "$TOOL" decompress - "$1" "$2" "${3:-}"; }

flip_byte() {
    local in="$1" offset="$2" out="$3" byte
    [[ "$offset" -ge 0 ]] || offset=$(($(stat -c '%s' "$in") + offset))
    cp -- "$in" "$out"
    byte="$(od -An -tu1 -j "$offset" -N1 -- "$in" | tr -d ' ')"
    # shellcheck disable=SC2059
    printf "\\x$(printf '%02x' $((byte ^ 255)))" | dd of="$out" bs=1 seek="$offset" conv=notrunc status=none
}

# expect_decode OP CHECK INPUT PLAIN [EXPECTED_BYTES]: blocking; the tool must decode INPUT to PLAIN.
expect_decode() {
    local op="$1" check="$2" input="$3" plain="$4" out="$WORK/out"
    attempt dec "$input" "$out" "${5:-}"
    if [[ "$ST" != 0 ]]; then
        rec "$op" "$check" blocking fail "status $ST $ERR"
    elif cmp -s "$out" "$plain"; then
        case "$check" in
            plaintext) rec "$op" "$check" blocking pass "$(stat -c '%s' "$out") bytes" ;;
            peer_encode) rec "$op" "$check" blocking pass "$(stat -c '%s' "$input") bytes" ;;
            *) rec "$op" "$check" blocking pass '' ;;
        esac
    else
        rec "$op" "$check" blocking fail 'decoded bytes differ from reference plaintext'
    fi
    rm -f -- "$out"
}

# expect_reject CHECK INPUT: blocking; the tool must exit non-zero.
expect_reject() {
    attempt dec "$2" "$WORK/out"
    if [[ "$ST" == 0 ]]; then
        rec decompress "$1" blocking fail 'accepted an invalid stream'
    else
        rec decompress "$1" blocking pass "status $ST $ERR"
    fi
    rm -f -- "$WORK/out"
}

# A flipped gzip trailer field: blocking when the tool claims the check, otherwise observed.
expect_trailer() {
    local check="$1" claimed="$2" input="$3" plain="$4"
    attempt gzip -t -- "$input"
    if [[ "$ST" == 0 ]]; then
        rec decompress "$check" observed fail "gzip -t accepted a flipped trailer field"
        return
    fi
    if [[ "$claimed" == yes ]]; then
        expect_reject "$check" "$input"
        return
    fi
    attempt dec "$input" "$WORK/out"
    if [[ "$ST" == 0 ]] && cmp -s "$WORK/out" "$plain"; then
        rec decompress "$check" observed gap "gzip -t rejects; $TOOL writes matching plaintext"
    elif [[ "$ST" == 0 ]]; then
        rec decompress "$check" observed fail "$TOOL exit 0 with wrong plaintext"
    else
        rec decompress "$check" observed pass "$TOOL status $ST $ERR"
    fi
    rm -f -- "$WORK/out"
}

qualify_empty() {
    local empty="$WORK/empty" gz="$WORK/empty.gz" out="$WORK/empty.out" level
    CAT=- CLS=- FILE=empty.gz
    : >"$empty"
    if [[ -z "$LEVELS" ]]; then
        if [[ "${P_FORMAT[$TOOL]}" == gzip ]]; then
            gzip -n -6 -c -- "$empty" >"$gz"
        else
            printf '\x78\x9c\x03\x00\x00\x00\x00\x01' >"$gz"
        fi
        expect_decode decompress empty "$gz" "$empty"
        return
    fi
    for level in $LEVELS; do
        attempt tool_run "$TOOL" compress "$level" "$empty" "$gz"
        if [[ "$ST" != 0 ]]; then
            rec compress "empty_$level" blocking fail "$ERR"
            continue
        fi
        attempt gzip -t -- "$gz"
        if [[ "$ST" != 0 ]]; then
            rec compress "empty_$level" blocking fail "reference decode status $ST $ERR"
            continue
        fi
        attempt dec "$gz" "$out"
        if [[ "$ST" != 0 ]]; then
            rec decompress "empty_$level" blocking fail "$ERR"
        elif ! cmp -s "$empty" "$out"; then
            rec compress "empty_$level" blocking fail 'round trip bytes differ'
        else
            rec compress "empty_$level" blocking pass "$(stat -c '%s' "$gz") bytes"
        fi
    done
}

qualify_zlib_file() {
    local input="$1" plain="$WORK/plain" bad="$WORK/bad.zlib" bytes
    attempt zlib_decode "$input" "$plain"
    if [[ "$ST" != 0 ]]; then
        rec decompress corpus_test blocking fail "status $ST $ERR"
        return
    fi
    rec decompress corpus_test blocking pass ''
    bytes="$(stat -c '%s' "$plain")"
    # The corpus zlib file is Python zlib level 6 of the plaintext, the reference every peer decodes.
    expect_decode decompress plaintext "$input" "$plain" "$bytes"
    [[ "$CLS" == sanity ]] || return 0
    expect_decode decompress stdin - "$plain" "$bytes" <"$input"
    head -c "$(($(stat -c '%s' "$input") - 1))" -- "$input" >"$bad"
    expect_reject truncated "$bad"
    { cat -- "$input" && printf 'tail'; } >"$bad"
    expect_reject trailing "$bad"
    flip_byte "$input" 0 "$bad" && expect_reject bad_method "$bad"
    flip_byte "$input" 1 "$bad" && expect_reject bad_fcheck "$bad"
    flip_byte "$input" 2 "$bad" && expect_reject bad_payload "$bad"
    flip_byte "$input" -1 "$bad" && expect_reject bad_adler "$bad"
    printf '\x78\x20\x00\x00\x00\x01' >"$bad"
    expect_reject dictionary "$bad"
    rec decompress bounds skip skip 'adapter CLI has no output cap flag'
}

qualify_gzip_file() {
    local gz="$1" plain="$WORK/plain" bad="$WORK/bad.gz" out="$WORK/out" new="$WORK/tool.gz" level
    attempt gzip -t -- "$gz"
    if [[ "$ST" != 0 ]]; then
        rec decompress corpus_test blocking fail "gzip -t status $ST $ERR"
        return
    fi
    rec decompress corpus_test blocking pass ''
    gzip -dc -- "$gz" >"$plain"
    expect_decode decompress plaintext "$gz" "$plain"

    if [[ "$CLS" == sanity ]]; then
        expect_decode decompress stdin - "$plain" <"$gz"

        cat -- "$gz" "$gz" >"$bad"
        cat -- "$plain" "$plain" >"$WORK/plain2"
        if [[ "${P_CONCAT[$TOOL]}" == yes ]]; then
            expect_decode decompress concat "$bad" "$WORK/plain2"
        else
            attempt dec "$bad" "$out"
            if [[ "$ST" != 0 ]]; then
                rec decompress concat observed fail "status $ST $ERR"
            elif cmp -s "$out" "$plain"; then
                rec decompress concat observed gap 'first member only; gzip -dc concatenates'
            else
                rec decompress concat observed fail 'output is not the first member'
            fi
        fi

        head -c "$(($(stat -c '%s' "$gz") - 8))" -- "$gz" >"$bad"
        expect_reject truncated "$bad"

        flip_byte "$gz" 64 "$bad"
        attempt dec "$bad" "$out"
        if [[ "$ST" != 0 ]]; then
            rec decompress corrupt_body observed pass "status $ST $ERR"
        elif cmp -s "$out" "$plain"; then
            rec decompress corrupt_body observed fail 'exit 0 and plaintext unchanged after body flip'
        else
            rec decompress corrupt_body observed gap 'exit 0 with wrong plaintext; no CRC stop'
        fi

        flip_byte "$gz" -8 "$bad" && expect_trailer corrupt_crc "${P_CRC[$TOOL]}" "$bad" "$plain"
        flip_byte "$gz" -1 "$bad" && expect_trailer corrupt_isize "${P_ISIZE[$TOOL]}" "$bad" "$plain"
        rec decompress bounds skip skip 'adapter has no output cap'
    fi

    gzip -n -6 -c -- "$plain" >"$bad"
    expect_decode compress peer_encode "$bad" "$plain"

    for level in $LEVELS; do
        attempt tool_run "$TOOL" compress "$level" "$plain" "$new"
        if [[ "$ST" != 0 ]]; then
            rec compress "write_$level" blocking fail "status $ST $ERR"
            continue
        fi
        rec compress "write_$level" blocking pass "$(stat -c '%s' "$new") bytes"
        attempt gzip -t -- "$new"
        if [[ "$ST" != 0 ]]; then
            rec compress "integrity_$level" blocking fail "reference decode status $ST $ERR"
            continue
        fi
        rec compress "integrity_$level" blocking pass ''
        gzip -dc -- "$new" >"$out"
        if cmp -s "$out" "$plain"; then
            rec compress "peer_decode_$level" blocking pass ''
        else
            rec compress "peer_decode_$level" blocking fail "reference decode of $TOOL output differs"
        fi
        expect_decode compress "roundtrip_$level" "$new" "$plain"
    done
}

qualify_tool() {
    local dir row rows category class filename
    TOOL="$1" BLOCKING_FAILS=0
    LEVELS="$(tool_levels "$TOOL")"
    "$TOOLS_DIR/install.sh" --check "$TOOL"
    dir="$LOCAL_DIR/qualify/$TOOL"
    mkdir -p "$dir"
    rm -f -- "$dir/meta.tsv" "$dir/sizes.tsv"
    CHECKS="$dir/checks.tsv"
    printf 'category\tclass\tfilename\top\tcheck\tkind\tresult\tdetail\n' >"$CHECKS"
    printf 'qualify %s levels: %s classes: %s\n' "$TOOL" "${LEVELS:--}" "$CLASSES"

    qualify_empty
    # Rows are read up front so no tool under test can consume the loop's input.
    mapfile -t rows < <(corpus_rows "${P_FORMAT[$TOOL]}")
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r category class filename <<<"$row"
        CAT="$category" CLS="$class" FILE="$filename"
        if [[ "${P_FORMAT[$TOOL]}" == gzip ]]; then
            qualify_gzip_file "$(data_path "$category" gzip "$class" "$filename")"
        else
            qualify_zlib_file "$(data_path "$category" zlib "$class" "$filename")"
        fi
        rm -f -- "$WORK"/plain* "$WORK"/bad.* "$WORK"/out "$WORK"/tool.gz
    done

    {
        printf 'schema\tzipir-qualify-v3\n'
        printf 'tool\t%s\ntool_version\t%s\nformat\t%s\ndecode\t%s\n' \
            "$TOOL" "$(tool_version_text "$TOOL")" "${P_FORMAT[$TOOL]}" "${P_DECODE[$TOOL]}"
        printf 'levels\t%s\nclasses\t%s\ncategory\t%s\n' "${LEVELS:--}" "$CLASSES" "$CATEGORY"
        printf 'binary\t%s\n' "$(tool_identity "$TOOL")"
        if [[ "${P_FORMAT[$TOOL]}" == gzip ]]; then
            printf 'oracle\t%s\n' "$(gzip --version | head -1)"
        else
            printf 'oracle\tpython-zlib %s\n' "$(python3 -c 'import zlib; print(zlib.ZLIB_RUNTIME_VERSION)')"
        fi
        host_state
        git_state
        printf 'blocking_fails\t%s\n' "$BLOCKING_FAILS"
        printf 'status\t%s\n' "$([[ "$BLOCKING_FAILS" == 0 ]] && printf pass || printf fail)"
    } >"$dir/receipt.tsv"
    if [[ "$BLOCKING_FAILS" != 0 ]]; then
        printf 'error: %s: %s blocking check(s) failed; see %s\n' "$TOOL" "$BLOCKING_FAILS" "$CHECKS" >&2
        return 1
    fi
    printf 'qualify pass: %s\n' "$dir/receipt.tsv"
}

main() {
    local tool tools rc status=0
    parse_run_args "$@"
    if [[ "$LIST" == 1 ]]; then
        run_tools | list_selection
        return
    fi
    require_linux_x64
    require_command gzip python3 od dd cmp
    make_work qualify
    mapfile -t tools < <(run_tools)
    # One tool per subshell with set -e active inside; every tool runs even after another fails.
    for tool in "${tools[@]}"; do
        set +e
        (
            set -e
            qualify_tool "$tool"
        )
        rc=$?
        set -e
        [[ "$rc" == 0 ]] || status=1
    done
    return "$status"
}

main "$@"
