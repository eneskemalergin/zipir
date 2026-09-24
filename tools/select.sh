#!/usr/bin/env bash
# shellcheck shell=bash
# Peer and level selection from tools/peers.tsv. Sourced by bench.sh, qualify.sh, and install.sh.
#
#   --peers prime     tier prime only (default; daily work)
#   --peers extended  tiers prime and extended
#   --peers all       every tool
#   --levels lanes    the fast, balanced, dense row of each compression tool (default)
#   --levels all      every compression level in peers.tsv
#
# Decode-only rows (level -) are always selected.

PEER_SET="${PEER_SET:-prime}"
LEVEL_SET="${LEVEL_SET:-lanes}"

check_selection() {
    case "$PEER_SET" in
        prime | extended | all) ;;
        *)
            printf 'error: --peers must be prime, extended, or all (got %s)\n' "$PEER_SET" >&2
            return 64
            ;;
    esac
    case "$LEVEL_SET" in
        lanes | all) ;;
        *)
            printf 'error: --levels must be lanes or all (got %s)\n' "$LEVEL_SET" >&2
            return 64
            ;;
    esac
}

tier_selected() {
    case "$PEER_SET:$1" in
        prime:prime | extended:prime | extended:extended | all:*) return 0 ;;
        *) return 1 ;;
    esac
}

row_selected() {
    local level="$1" lane="$2"
    [[ "$level" == - || "$LEVEL_SET" == all || "$lane" != - ]]
}

# Every tool in the selected peer set, in peers.tsv order.
selected_tools() {
    local tool _ver _fmt _level _threads _nthreads tier _lane
    local -A seen=()
    while IFS=$'\t' read -r tool _ver _fmt _level _threads _nthreads tier _lane; do
        [[ -z "${tool:-}" || "$tool" == \#* || "$tool" == tool ]] && continue
        [[ -n "${seen[$tool]:-}" ]] && continue
        seen[$tool]=1
        if tier_selected "$tier"; then
            printf '%s\n' "$tool"
        fi
    done <"$TOOLS_DIR/peers.tsv"
}

# Planned matrix rows: tool format level lane. With a tool name, that tool's rows whatever its tier
# (a named tool always runs); without one, every tool in the selected peer set.
selected_rows() {
    local only="${1:-}" tool _ver fmt level _threads _nthreads tier lane
    while IFS=$'\t' read -r tool _ver fmt level _threads _nthreads tier lane; do
        [[ -z "${tool:-}" || "$tool" == \#* || "$tool" == tool ]] && continue
        if [[ -n "$only" ]]; then
            [[ "$tool" == "$only" ]] || continue
        else
            tier_selected "$tier" || continue
        fi
        row_selected "$level" "$lane" || continue
        printf '%s\t%s\t%s\t%s\n' "$tool" "$fmt" "$level" "$lane"
    done <"$TOOLS_DIR/peers.tsv"
}
