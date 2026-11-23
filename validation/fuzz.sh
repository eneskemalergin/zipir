#!/usr/bin/env bash
# Runs a coverage-guided fuzz campaign over validation/fuzz.zig and fails if any target found a crash: the Zig 0.16
# runner saves a crashing input and still exits 0, so the log and the saved input decide.
#   validation/fuzz.sh RUNS [LOG]      a campaign of RUNS (zig build fuzz --fuzz=RUNS) in ReleaseSafe
#   validation/fuzz.sh --self-check    builds the planted target and requires the campaign to find its crash
set -euo pipefail
cd "$(dirname "$0")"

self_check=false
if [[ "${1:-}" == --self-check ]]; then
    self_check=true
    runs=2000000
    log=${2:-$(mktemp /var/tmp/zipir-fuzz-check.XXXXXX)}
else
    runs=${1:?usage: fuzz.sh RUNS [LOG] | fuzz.sh --self-check [LOG]}
    log=${2:-$(mktemp /var/tmp/zipir-fuzz.XXXXXX)}
fi

crash=.zig-cache/f/crash
if [[ -e "$crash" ]]; then
    printf 'fuzz.sh: %s exists from an earlier run; move it away first\n' "$crash" >&2
    exit 2
fi

status=0
zig build fuzz -Doptimize=ReleaseSafe -Dplanted="$self_check" --fuzz="$runs" >"$log" 2>&1 || status=$?
grep -E '^(Fuzz test|Runs|Unique runs|Coverage):' "$log" || true

found=false
if grep -q 'input saved to' "$log" || [[ -e "$crash" ]]; then
    found=true
fi

if [[ "$self_check" == true ]]; then
    if [[ "$found" == true ]] && grep -q 'planted' "$log"; then
        rm -f -- "$crash"
        printf 'fuzz.sh: self-check passed: the runner found the planted crash (log %s)\n' "$log"
        exit 0
    fi
    printf 'fuzz.sh: self-check failed: the planted crash was not found (log %s)\n' "$log" >&2
    exit 1
fi
if [[ "$found" == true ]]; then
    printf 'fuzz.sh: a target crashed; the input is %s and the log %s\n' "$crash" "$log" >&2
    exit 1
fi
if [[ "$status" -ne 0 ]]; then
    printf 'fuzz.sh: zig build exited %d (log %s)\n' "$status" "$log" >&2
    exit "$status"
fi
printf 'fuzz.sh: no crash in %s runs (log %s)\n' "$runs" "$log"
