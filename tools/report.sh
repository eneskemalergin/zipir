#!/usr/bin/env bash
# Build comparison views from keyed Zebrac JSON, qualify sizes, and coverage.tsv.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    printf '%s\n' \
        'usage: tools/report.sh [--check]' \
        '' \
        'Reads tools/peers.tsv, tools/coverage.tsv, tools/levels.tsv,' \
        'tools/.local/qualify/, and tools/.local/zebrac/. Writes' \
        'tools/.local/report/ (facts.tsv, headline.tsv, gmean.tsv). If' \
        'tools/README.md exists, generated sections are updated there.' \
        'JSON layout: zebrac/TOOL/FORMAT/LEVEL/THREADS/category.class.op.json' \
        'Decompress LEVEL is -.'
}

case "${1:-}" in
    --help | -h)
        usage
        exit 0
        ;;
esac

exec python3 "$TOOLS_DIR/report.py" "$@"
