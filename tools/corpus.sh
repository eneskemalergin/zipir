#!/usr/bin/env bash
# Fetch or derive every corpus file listed in tools/corpus.tsv into gitignored data/.
# One row per category, class, and format; data/{category}/{format}/{class}/{filename}.

set -euo pipefail
# shellcheck source=tools/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
BGZIP="$BIN_DIR/bgzip"
FORCE=0

usage() {
    printf '%s\n' \
        'usage: tools/corpus.sh [CATEGORY|all]' \
        '       tools/corpus.sh --check [CATEGORY|all]' \
        '       tools/corpus.sh --list' \
        '       tools/corpus.sh --force [CATEGORY|all]' \
        '' \
        'categories: sequencing, ms, generalized' \
        'formats: gzip, zlib, bgzf' \
        '' \
        'Reads tools/corpus.tsv. Writes gitignored data/. Requires curl, gzip, sha256sum, python3.' \
        'Rows derived with bgzip-6 also need tools/bin/bgzip (tools/install.sh bgzip).'
}

# Prints valid rows as: category class format filename bytes sha256 source.
each_row() {
    local filter="$1" category class format filename bytes sha256 source key
    local -A seen=()
    [[ -f "$MANIFEST" ]] || {
        printf 'error: missing manifest: %s\n' "$MANIFEST" >&2
        return 1
    }
    while IFS=$'\t' read -r category class format filename bytes sha256 source; do
        [[ -z "${category:-}" || "$category" == \#* || "$category" == category ]] && continue
        case "$class" in
            sanity | small | medium | large) ;;
            *)
                printf 'error: unknown size class in manifest: %s\n' "$class" >&2
                return 1
                ;;
        esac
        case "$format" in
            gzip | zlib | deflate | bgzf) ;;
            *)
                printf 'error: unknown format in manifest: %s\n' "$format" >&2
                return 1
                ;;
        esac
        key="$category/$class/$format"
        [[ -z "${seen[$key]:-}" ]] || {
            printf 'error: more than one manifest row for %s\n' "$key" >&2
            return 1
        }
        seen[$key]=1
        case "$source" in
            derive:zlib-6 | derive:deflate-6 | derive:bgzip-6)
                local recipe_format=zlib
                [[ "$source" == derive:bgzip-6 ]] && recipe_format=bgzf
                [[ "$source" == derive:deflate-6 ]] && recipe_format=deflate
                [[ "$bytes" == - && "$sha256" == - && "$format" == "$recipe_format" ]] || {
                    printf 'error: derived row needs - for bytes and sha256 and format %s: %s\n' "$recipe_format" "$key" >&2
                    return 1
                }
                ;;
            derive:*)
                printf 'error: unknown derive recipe for %s: %s\n' "$key" "$source" >&2
                return 1
                ;;
            *)
                [[ "$bytes" =~ ^[1-9][0-9]*$ && "$sha256" =~ ^[0-9a-f]{64}$ ]] || {
                    printf 'error: fetched row needs bytes and sha256: %s\n' "$key" >&2
                    return 1
                }
                ;;
        esac
        if [[ "$filter" != all && "$category" != "$filter" ]]; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$category" "$class" "$format" "$filename" "$bytes" "$sha256" "$source"
    done <"$MANIFEST"
}

# The gzip row of a category and class supplies the plaintext for derived rows.
gzip_source_for() {
    local category class format filename _rest
    while IFS=$'\t' read -r category class format filename _rest; do
        if [[ "$category" == "$1" && "$class" == "$2" && "$format" == gzip ]]; then
            data_path "$category" gzip "$class" "$filename"
            return
        fi
    done < <(each_row all)
    printf 'error: no gzip row for %s/%s\n' "$1" "$2" >&2
    return 1
}

verify_size_sha() {
    local path="$1" bytes="$2" sha256="$3" actual
    [[ -f "$path" ]] || return 1
    actual="$(stat -c '%s' "$path")"
    if [[ "$actual" != "$bytes" ]]; then
        printf 'error: size mismatch %s: got %s expected %s\n' "$path" "$actual" "$bytes" >&2
        return 1
    fi
    printf '%s  %s\n' "$sha256" "$path" | sha256sum -c --status || {
        printf 'error: sha256 mismatch: %s\n' "$path" >&2
        return 1
    }
}

verify_zlib_file() {
    zlib_decode "$1" /dev/stdout | cmp -s - <(gzip -dc -- "$2") || {
        printf 'error: %s does not decode to the plaintext of %s\n' "$1" "$2" >&2
        return 1
    }
}

verify_deflate_file() {
    deflate_decode "$1" /dev/stdout | cmp -s - <(gzip -dc -- "$2") || {
        printf 'error: %s does not decode to the plaintext of %s\n' "$1" "$2" >&2
        return 1
    }
}

# Content check of one file. Derived rows pass their gzip source so decoded bytes are compared.
verify_format() {
    local format="$1" path="$2" source="${3:-}"
    case "$format" in
        gzip) gzip -t "$path" ;;
        zlib)
            [[ -n "$source" ]] || {
                printf 'error: zlib rows are derived and need their gzip source\n' >&2
                return 1
            }
            verify_zlib_file "$path" "$source"
            ;;
        deflate)
            [[ -n "$source" ]] || {
                printf 'error: deflate rows are derived and need their gzip source\n' >&2
                return 1
            }
            verify_deflate_file "$path" "$source"
            ;;
        bgzf) gzip -t "$path" && verify_bgzf_file "$path" "$source" ;;
        *) return 64 ;;
    esac
}

recipe_tool() {
    case "$1" in
        derive:zlib-6 | derive:deflate-6) python3 -c 'import zlib; print("python-zlib", zlib.ZLIB_RUNTIME_VERSION)' ;;
        derive:bgzip-6)
            [[ -x "$BGZIP" && "$("$BGZIP" --version | awk 'NR==1{print $3}')" == "$HTSLIB_VERSION" ]] || {
                printf 'error: %s needs bgzip %s; run tools/install.sh bgzip\n' "$1" "$HTSLIB_VERSION" >&2
                return 1
            }
            printf 'bgzip %s\n' "$HTSLIB_VERSION"
            ;;
        *) return 64 ;;
    esac
}

sidecar_for() {
    printf '%s.derive.tsv\n' "$1"
}

# Identity of a derived file: recipe, tool, and the size and mtime of its source and itself.
sidecar_text() {
    local dest="$1" source="$2" recipe="$3"
    printf 'recipe\t%s\n' "$recipe"
    printf 'tool\t%s\n' "$(recipe_tool "$recipe")"
    printf 'source\t%s\n' "${source#"$DATA_DIR"/}"
    printf 'source_bytes\t%s\nsource_mtime\t%s\n' "$(stat -c '%s' "$source")" "$(stat -c '%Y' "$source")"
    printf 'bytes\t%s\nmtime\t%s\n' "$(stat -c '%s' "$dest")" "$(stat -c '%Y' "$dest")"
}

derived_current() {
    local dest="$1" source="$2" recipe="$3" sidecar
    sidecar="$(sidecar_for "$dest")"
    [[ -f "$dest" && -f "$source" && -f "$sidecar" ]] || return 1
    [[ "$(cat "$sidecar")" == "$(sidecar_text "$dest" "$source" "$recipe")" ]]
}

derive_file() {
    local dest="$1" source="$2" recipe="$3" part="$1.part" recipe_format
    recipe_tool "$recipe" >/dev/null
    [[ -f "$source" ]] || {
        printf 'error: missing gzip source %s\n' "$source" >&2
        return 1
    }
    mkdir -p "$(dirname "$dest")"
    rm -f -- "$part" "$(sidecar_for "$dest")"
    printf 'derive: %s (%s)\n' "$dest" "${recipe#derive:}"
    case "$recipe" in
        derive:zlib-6 | derive:deflate-6)
            python3 - "$source" "$part" "$recipe" <<'PY' || {
import gzip
import sys
import zlib

gzip_path, zlib_path, recipe = sys.argv[1:]
wbits = -zlib.MAX_WBITS if recipe == "derive:deflate-6" else zlib.MAX_WBITS
compressor = zlib.compressobj(6, zlib.DEFLATED, wbits)
with gzip.open(gzip_path, "rb") as source, open(zlib_path, "wb") as output:
    while True:
        chunk = source.read(1024 * 1024)
        if not chunk:
            break
        output.write(compressor.compress(chunk))
    output.write(compressor.flush())
PY
                rm -f -- "$part"
                return 1
            }
            recipe_format="${recipe#derive:}"
            verify_format "${recipe_format%-6}" "$part" "$source" || {
                rm -f -- "$part"
                return 1
            }
            ;;
        derive:bgzip-6)
            gzip -dc -- "$source" | "$BGZIP" -l 6 -@ 1 -c >"$part" || {
                rm -f -- "$part"
                return 1
            }
            verify_format bgzf "$part" "$source" || {
                rm -f -- "$part"
                return 1
            }
            ;;
        *) return 64 ;;
    esac
    mv -f -- "$part" "$dest"
    sidecar_text "$dest" "$source" "$recipe" >"$(sidecar_for "$dest")"
}

fetch_row() {
    local category="$1" class="$2" format="$3" filename="$4" bytes="$5" sha256="$6" source="$7"
    local dest part actual digest gzip_source
    dest="$(data_path "$category" "$format" "$class" "$filename")"
    if [[ "$source" == derive:* ]]; then
        gzip_source="$(gzip_source_for "$category" "$class")"
        if [[ "$FORCE" != 1 ]] && derived_current "$dest" "$gzip_source" "$source"; then
            printf 'ok: %s\n' "$dest"
            return
        fi
        # Adopt a file made by an earlier corpus.sh when it still verifies, so its bytes stay stable.
        if [[ "$FORCE" != 1 && -f "$dest" && ! -f "$(sidecar_for "$dest")" ]] &&
            verify_format "$format" "$dest" "$gzip_source"; then
            sidecar_text "$dest" "$gzip_source" "$source" >"$(sidecar_for "$dest")"
            printf 'adopted: %s\n' "$dest"
            return
        fi
        derive_file "$dest" "$gzip_source" "$source"
        printf 'derived: %s\n' "$dest"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    if [[ "$FORCE" != 1 && -f "$dest" ]] && verify_size_sha "$dest" "$bytes" "$sha256" && verify_format "$format" "$dest"; then
        printf 'ok: %s\n' "$dest"
        return
    fi
    part="$dest.part"
    rm -f -- "$part"
    printf 'fetch: %s (%s bytes)\n' "$dest" "$bytes"
    curl -fL --retry 5 --retry-delay 2 --progress-bar -o "$part" "$source"
    actual="$(stat -c '%s' "$part")"
    digest="$(sha256sum "$part" | awk '{print $1}')"
    if [[ "$actual" != "$bytes" || "$digest" != "$sha256" ]]; then
        printf 'error: size or sha256 mismatch for %s: got %s %s\n' "$source" "$actual" "$digest" >&2
        rm -f -- "$part"
        return 1
    fi
    verify_format "$format" "$part" || {
        rm -f -- "$part"
        return 1
    }
    mv -f -- "$part" "$dest"
    printf 'fetched: %s\n' "$dest"
}

check_row() {
    local category="$1" class="$2" format="$3" filename="$4" bytes="$5" sha256="$6" source="$7"
    local dest gzip_source
    dest="$(data_path "$category" "$format" "$class" "$filename")"
    if [[ "$source" == derive:* ]]; then
        gzip_source="$(gzip_source_for "$category" "$class")"
        derived_current "$dest" "$gzip_source" "$source" || {
            printf 'error: derived file missing or stale: %s\n' "$dest" >&2
            return 1
        }
        verify_format "$format" "$dest" "$gzip_source"
    else
        verify_size_sha "$dest" "$bytes" "$sha256"
        verify_format "$format" "$dest"
    fi
    printf 'ok: %s\n' "$dest"
}

list_rows() {
    local category class format filename bytes sha256 source dest state rows
    rows="$(each_row all)"
    printf '%-12s %-8s %-6s %-8s %s\n' 'category' 'class' 'format' 'state' 'path'
    while IFS=$'\t' read -r category class format filename bytes sha256 source; do
        dest="$(data_path "$category" "$format" "$class" "$filename")"
        if [[ "$source" == derive:* ]]; then
            if derived_current "$dest" "$(gzip_source_for "$category" "$class")" "$source" 2>/dev/null; then
                state=ok
            elif [[ -f "$dest" ]]; then
                state=stale
            else
                state=missing
            fi
        elif [[ -f "$dest" ]] && verify_size_sha "$dest" "$bytes" "$sha256" >/dev/null 2>&1; then
            state=ok
        elif [[ -f "$dest" ]]; then
            state=bad
        else
            state=missing
        fi
        printf '%-12s %-8s %-6s %-8s %s\n' "$category" "$class" "$format" "$state" "$dest"
    done <<<"$rows"
}

main() {
    local mode=fetch filter=all
    require_command curl gzip sha256sum python3
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
            filter="$(expand_category "${2:-all}")"
            [[ $# -le 2 ]] || {
                usage >&2
                return 64
            }
            ;;
        --force)
            FORCE=1
            filter="$(expand_category "${2:-all}")"
            [[ $# -le 2 ]] || {
                usage >&2
                return 64
            }
            ;;
        '') ;;
        *)
            filter="$(expand_category "$1")"
            [[ $# -eq 1 ]] || {
                usage >&2
                return 64
            }
            ;;
    esac
    local rows pass category class format filename bytes sha256 source
    # Rows are read up front so a manifest error stops the run before any fetch.
    rows="$(each_row "$filter")"
    # Fetched rows first: derived rows read the gzip row of their slot.
    for pass in fetched derived; do
        while IFS=$'\t' read -r category class format filename bytes sha256 source; do
            [[ -z "${category:-}" ]] && continue
            if [[ "$pass" == fetched && "$source" == derive:* ]] || [[ "$pass" == derived && "$source" != derive:* ]]; then
                continue
            fi
            if [[ "$mode" == check ]]; then
                check_row "$category" "$class" "$format" "$filename" "$bytes" "$sha256" "$source"
            else
                fetch_row "$category" "$class" "$format" "$filename" "$bytes" "$sha256" "$source"
            fi
        done <<<"$rows"
    done
}

main "$@"
