#!/usr/bin/env bash
# Fetch public gzip files into gitignored data/{category}/gzip/{class}/.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
MANIFEST="$TOOLS_DIR/corpus.tsv"
DATA_DIR="$ROOT_DIR/data"
FORCE=0

usage() {
    printf '%s\n' \
        'usage: tools/corpus.sh [CATEGORY|all]' \
        '       tools/corpus.sh --check [CATEGORY|all]' \
        '       tools/corpus.sh --list' \
        '       tools/corpus.sh --force [CATEGORY|all]' \
        '' \
        'categories: sequencing, ms, generalized' \
        '' \
        'Reads tools/corpus.tsv. Writes gitignored data/. Requires curl, gzip, sha256sum.'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: required command not found: %s\n' "$1" >&2
        return 1
    }
}

expand_filter() {
    case "$1" in
        all | '') printf '%s\n' all ;;
        sequencing | ms | generalized) printf '%s\n' "$1" ;;
        *)
            printf 'error: unknown category: %s\n' "$1" >&2
            return 64
            ;;
    esac
}

each_row() {
    local filter="$1" category class filename bytes sha256 url
    [[ -f "$MANIFEST" ]] || {
        printf 'error: missing manifest: %s\n' "$MANIFEST" >&2
        return 1
    }
    while IFS=$'\t' read -r category class filename bytes sha256 url; do
        [[ -z "${category:-}" || "$category" == \#* || "$category" == category ]] && continue
        if [[ "$filter" != all && "$category" != "$filter" ]]; then
            continue
        fi
        case "$class" in
            sanity | small | medium | large) ;;
            *)
                printf 'error: unknown size class in manifest: %s\n' "$class" >&2
                return 1
                ;;
        esac
        [[ "$bytes" =~ ^[1-9][0-9]*$ ]] || {
            printf 'error: invalid byte size for %s: %s\n' "$filename" "$bytes" >&2
            return 1
        }
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$category" "$class" "$filename" "$bytes" "$sha256" "$url"
    done <"$MANIFEST"
}

dest_for() {
    printf '%s/%s/gzip/%s/%s\n' "$DATA_DIR" "$1" "$2" "$3"
}

verify_file() {
    local path="$1" bytes="$2" sha256="$3"
    local actual
    [[ -f "$path" ]] || return 1
    actual="$(stat -c '%s' "$path")"
    if [[ "$actual" != "$bytes" ]]; then
        printf 'error: size mismatch %s: got %s expected %s\n' \
            "$path" "$actual" "$bytes" >&2
        return 1
    fi
    gzip -t "$path" || {
        printf 'error: gzip -t failed: %s\n' "$path" >&2
        return 1
    }
    if [[ "$sha256" != - ]]; then
        printf '%s  %s\n' "$sha256" "$path" | sha256sum -c --status || {
            printf 'error: sha256 mismatch: %s\n' "$path" >&2
            return 1
        }
    fi
}

fetch_row() {
    local category="$1" class="$2" filename="$3" bytes="$4" sha256="$5" url="$6"
    local dest part actual digest
    dest="$(dest_for "$category" "$class" "$filename")"
    mkdir -p "$(dirname "$dest")"
    if [[ "$FORCE" != 1 && -f "$dest" ]] && verify_file "$dest" "$bytes" "$sha256"; then
        printf 'ok: %s\n' "$dest"
        return
    fi
    part="$dest.part"
    rm -f -- "$part"
    printf 'fetch: %s (%s bytes)\n' "$dest" "$bytes"
    curl -fL --retry 5 --retry-delay 2 --progress-bar -o "$part" "$url"
    actual="$(stat -c '%s' "$part")"
    if [[ "$actual" != "$bytes" ]]; then
        printf 'error: download size mismatch %s: got %s expected %s\n' \
            "$url" "$actual" "$bytes" >&2
        rm -f -- "$part"
        return 1
    fi
    gzip -t "$part" || {
        printf 'error: downloaded file is not valid gzip: %s\n' "$url" >&2
        rm -f -- "$part"
        return 1
    }
    digest="$(sha256sum "$part" | awk '{print $1}')"
    if [[ "$sha256" != - && "$digest" != "$sha256" ]]; then
        printf 'error: sha256 mismatch for %s: got %s expected %s\n' \
            "$url" "$digest" "$sha256" >&2
        rm -f -- "$part"
        return 1
    fi
    mv -f -- "$part" "$dest"
    if [[ "$sha256" == - ]]; then
        printf 'fetched: %s sha256=%s (record in corpus.tsv)\n' "$dest" "$digest"
    else
        printf 'fetched: %s\n' "$dest"
    fi
}

list_rows() {
    local category class filename bytes sha256 url dest state
    printf '%-12s %-8s %-12s %s\n' 'category' 'class' 'state' 'path'
    while IFS=$'\t' read -r category class filename bytes sha256 url; do
        [[ -z "${category:-}" || "$category" == \#* || "$category" == category ]] && continue
        dest="$(dest_for "$category" "$class" "$filename")"
        if [[ -f "$dest" ]] && verify_file "$dest" "$bytes" "$sha256" >/dev/null 2>&1; then
            state=ok
        elif [[ -f "$dest" ]]; then
            state=bad
        else
            state=missing
        fi
        printf '%-12s %-8s %-12s %s\n' "$category" "$class" "$state" "$dest"
    done < <(each_row all)
}

main() {
    local mode=fetch filter=all
    require_command curl
    require_command gzip
    require_command sha256sum
    case "${1:-}" in
        --help | -h)
            usage
            return
            ;;
        --list)
            [[ $# -eq 1 ]] || {
                usage >&2
                return 64
            }
            list_rows
            return
            ;;
        --check)
            mode=check
            filter="$(expand_filter "${2:-all}")"
            [[ $# -le 2 ]] || {
                usage >&2
                return 64
            }
            ;;
        --force)
            FORCE=1
            filter="$(expand_filter "${2:-all}")"
            [[ $# -le 2 ]] || {
                usage >&2
                return 64
            }
            ;;
        '') ;;
        *)
            filter="$(expand_filter "$1")"
            [[ $# -eq 1 ]] || {
                usage >&2
                return 64
            }
            ;;
    esac
    local category class filename bytes sha256 url dest
    while IFS=$'\t' read -r category class filename bytes sha256 url; do
        dest="$(dest_for "$category" "$class" "$filename")"
        if [[ "$mode" == check ]]; then
            verify_file "$dest" "$bytes" "$sha256"
            printf 'ok: %s\n' "$dest"
        else
            fetch_row "$category" "$class" "$filename" "$bytes" "$sha256" "$url"
        fi
    done < <(each_row "$filter")
}

main "$@"
