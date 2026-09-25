#!/usr/bin/env bash
# Matched timing with Zebrac: one batch per corpus file and operation, with every selected tool
# and level interleaved in the same rounds on one pinned CPU. Writes tools/.local/bench/RUN/,
# then runs tools/report.py RUN. Not a project L3 gate.

set -euo pipefail
# shellcheck source=tools/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
ALLOW_FORCE=1
BENCH_CPU="${BENCH_CPU:-4}"
RUN=""

usage() {
    printf '%s\n' \
        'usage: tools/bench.sh [--peers SET] [--levels SET] [--category C] [--class C | --full] [--force] [--list] [TOOL...]' \
        '' \
        'Without TOOL, times the selected peer set; named tools run whatever their tier. The zipir' \
        'tool of each format is always in the batch: it is the anchor every row is compared with.' \
        '--peers prime|extended|all   peer tiers from tools/peers.tsv (default prime)' \
        '--levels lanes|all           fast/balanced/dense lanes or every level (default lanes)' \
        '--category sequencing|ms|generalized, --class sanity|small|medium|large|all' \
        '--full                       every class (default classes are sanity and small)' \
        '--force                      re-time batches that are already complete' \
        '--list                       print the planned matrix and corpus size; run nothing' \
        '' \
        'Daily work uses the defaults. --peers all --levels all --full is for publication runs.' \
        'Every tool needs a passing tools/qualify.sh receipt for its current binary and levels.' \
        'Sampling: 3 warmups, exactly 25 rounds, taskset -c BENCH_CPU (default 4).' \
        'A batch is skipped when its tools, levels, binaries, and input are unchanged.'
}

# Identity of a batch: subjects, their binaries, the input file, and the sampling settings.
batch_key() {
    local input="$1" subject
    shift
    printf 'input %s %s %s; cpu %s; w3 n25' "${input#"$ROOT_DIR"/}" "$(stat -c '%s' "$input")" "$(stat -c '%Y' "$input")" "$BENCH_CPU"
    for subject in "$@"; do
        printf '; %s %s %s' "$subject" "$(lane_of "${subject%% *}" "${subject##* }")" "$(tool_identity "${subject%% *}")"
    done
}

batch_complete() {
    jq -e --argjson n "$2" \
        '(.results | length) == $n and all(.results[]; .sample_count == 25 and .failed_sample_count == 0)' \
        "$1" >/dev/null 2>&1
}

# run_batch FORMAT OP CATEGORY CLASS INPUT SUBJECT...  (SUBJECT is "tool level"; level - decodes)
run_batch() {
    local format="$1" op="$2" category="$3" class="$4" input="$5"
    shift 5
    local base="$LOCAL_DIR/bench/$RUN/$format/$op/$category.$class" plain="$WORK/plain"
    local key plain_bytes subject tool level bytes load_before cmds=() rows=()
    key="$(batch_key "$input" "$@")"
    if [[ "$FORCE" != 1 && -f "$base.tsv" ]] && batch_complete "$base.json" $# &&
        [[ "$(awk -F'\t' '$1 == "# key" { print $2 }' "$base.tsv")" == "$key" ]]; then
        printf 'skip: %s (complete)\n' "${base#"$ROOT_DIR"/}"
        return
    fi
    # Decoded only when a batch actually runs; large files are slow to decode.
    [[ -f "$plain" ]] || plain_of "$format" "$input" "$plain"
    plain_bytes="$(stat -c '%s' "$plain")"
    for subject in "$@"; do
        read -r tool level <<<"$subject"
        if [[ "$op" == compress ]]; then
            # Bytes come from the binary being timed, and must decode to the input.
            tool_run "$tool" compress "$level" "$plain" "$WORK/out"
            gzip -dc -- "$WORK/out" | cmp -s - "$plain" || die "$tool -$level output does not decode to $input"
            bytes="$(stat -c '%s' "$WORK/out")"
            cmds+=("$(zebrac_cmd "$tool" compress "$level" "$plain")")
        else
            bytes="$(stat -c '%s' "$input")"
            cmds+=("$(zebrac_cmd "$tool" decompress - "$input" "$plain_bytes")")
        fi
        rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$tool" "$level" "$(lane_of "$tool" "$level")" "${P_DECODE[$tool]}" "$bytes")")
    done
    rm -f -- "$WORK/out"
    mkdir -p "$(dirname "$base")"
    printf 'time: %s %s %s.%s, %s subjects\n' "$format" "$op" "$category" "$class" $#
    load_before="$(cut -d' ' -f1-3 /proc/loadavg)"
    taskset -c "$BENCH_CPU" zebrac --color never -q -w 3 -i 25 -a 25 -d 1 \
        --json="$base.part.json" -- "${cmds[@]}" >/dev/null
    batch_complete "$base.part.json" $# || die "incomplete Zebrac batch: $base.part.json"
    [[ "$(jq -r '.results[].command' "$base.part.json")" == "$(printf '%s\n' "${cmds[@]}")" ]] ||
        die "Zebrac commands do not match the planned subjects: $base.part.json"
    {
        printf '# key\t%s\n' "$key"
        printf '# format\t%s\n# op\t%s\n# category\t%s\n# class\t%s\n' "$format" "$op" "$category" "$class"
        printf '# input\t%s\n# input_bytes\t%s\n# plain_bytes\t%s\n' "${input#"$ROOT_DIR"/}" "$(stat -c '%s' "$input")" "$plain_bytes"
        printf '# load_before\t%s\n# load_after\t%s\n# cpu\t%s\n' "$load_before" "$(cut -d' ' -f1-3 /proc/loadavg)" "$BENCH_CPU"
        host_state | sed 's/^/# /'
        git_state | sed 's/^/# /'
        printf 'tool\tlevel\tlane\tdecode\tcompressed_bytes\n'
        printf '%s\n' "${rows[@]}"
    } >"$base.part.tsv"
    # JSON first: a crash between the two moves leaves the old key, so the batch is re-timed.
    mv -f -- "$base.part.json" "$base.json"
    mv -f -- "$base.part.tsv" "$base.tsv"
}

main() {
    local tools=() rows=() row tool format category class filename input level comp decomp
    parse_run_args "$@"
    mapfile -t tools < <(run_tools)
    # Every format in the run gets its zipir tool as the anchor.
    for format in gzip zlib; do
        for tool in "${tools[@]}"; do
            if [[ "${P_FORMAT[$tool]}" == "$format" && " ${tools[*]} " != *" zipir-$format "* ]]; then
                tools=("zipir-$format" "${tools[@]}")
                break
            fi
        done
    done
    if [[ ${#NAMED[@]} -gt 0 ]]; then
        RUN="named-$(IFS=+ && printf '%s' "${NAMED[*]}")-$LEVEL_SET"
    else
        RUN="$PEER_SET-$LEVEL_SET"
    fi
    if [[ "$LIST" == 1 ]]; then
        printf '%s\n' "${tools[@]}" | list_selection
        printf 'results: tools/.local/bench/%s/\n' "$RUN"
        return
    fi

    require_linux_x64
    require_command zebrac taskset jq gzip python3 cmp
    [[ "$(zebrac --help 2>&1 | awk 'NR==1{print $2}')" == 0.6.2 ]] || die "bench requires zebrac 0.6.2"
    [[ "$BENCH_CPU" =~ ^[0-9]+$ && "$BENCH_CPU" -lt "$(nproc)" ]] || die "BENCH_CPU must be a CPU number below $(nproc)"
    for tool in "${tools[@]}"; do
        # shellcheck disable=SC2046
        require_qualified "$tool" $(tool_levels "$tool")
    done
    make_work bench

    for format in gzip zlib; do
        comp=() decomp=()
        for tool in "${tools[@]}"; do
            [[ "${P_FORMAT[$tool]}" == "$format" ]] || continue
            decomp+=("$tool -")
            for level in $(tool_levels "$tool"); do comp+=("$tool $level"); done
        done
        [[ ${#decomp[@]} -gt 0 ]] || continue
        # Rows are read up front so nothing timed can consume the loop's input.
        mapfile -t rows < <(corpus_rows "$format")
        for row in "${rows[@]}"; do
            IFS=$'\t' read -r category class filename <<<"$row"
            input="$(data_path "$category" "$format" "$class" "$filename")"
            if [[ ${#comp[@]} -gt 0 ]]; then
                run_batch "$format" compress "$category" "$class" "$input" "${comp[@]}"
            fi
            run_batch "$format" decompress "$category" "$class" "$input" "${decomp[@]}"
            rm -f -- "$WORK/plain"
        done
    done
    python3 "$TOOLS_DIR/report.py" "$RUN"
}

main "$@"
