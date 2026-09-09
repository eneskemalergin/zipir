#!/usr/bin/env bash
# Native argv for C/host gzip CLIs. Uniform path CLI for language adapters.
# Sourced by qualify.sh and bench.sh. Not a timed program.

# shellcheck source=versions.sh
source "${TOOLS_DIR}/versions.sh"

BIN_DIR="${BIN_DIR:-$TOOLS_DIR/bin}"
LOCAL_DIR="${LOCAL_DIR:-$TOOLS_DIR/.local}"
INSTALLS_DIR="${INSTALLS_DIR:-$LOCAL_DIR/installs}"

tool_engine() {
    local name="${1:-${TOOL:?}}"
    case "$name" in
        gnu-gzip) printf '%s\n' "$GNU_GZIP_BIN" ;;
        pigz) printf '%s\n' "$PIGZ_BIN" ;;
        libdeflate-gzip)
            printf '%s\n' "$INSTALLS_DIR/libdeflate-gzip/$LIBDEFLATE_VERSION/bin/libdeflate-gzip"
            ;;
        igzip) printf '%s\n' "$INSTALLS_DIR/igzip/$ISAL_VERSION/bin/igzip" ;;
        zlib-ng) printf '%s\n' "$INSTALLS_DIR/zlib-ng/$ZLIB_NG_VERSION/bin/zlib-ng" ;;
        std-gzip | flate2-miniz | flate2-zlib-rs)
            printf '%s\n' "$BIN_DIR/$name"
            ;;
        *)
            printf 'error: unknown tool: %s\n' "$name" >&2
            return 64
            ;;
    esac
}

tool_is_adapter() {
    case "${1:-${TOOL:?}}" in
        std-gzip | flate2-miniz | flate2-zlib-rs) return 0 ;;
        *) return 1 ;;
    esac
}

tool_version_text() {
    local name="${1:-${TOOL:?}}" engine
    engine="$(tool_engine "$name")"
    case "$name" in
        gnu-gzip) "$engine" --version | awk 'NR==1{print $2}' ;;
        pigz) "$engine" --version | awk '{print $2; exit}' ;;
        libdeflate-gzip) "$engine" -V | awk 'NR==1{v=$NF; sub(/^v/, "", v); print v}' ;;
        igzip) printf '%s\n' "$ISAL_VERSION" ;;
        zlib-ng) printf '%s\n' "$ZLIB_NG_VERSION" ;;
        std-gzip | flate2-miniz | flate2-zlib-rs)
            "$engine" --version | awk '{print $2}'
            ;;
        *) return 64 ;;
    esac
}

# Write compressed bytes from IN to OUT. IN may be - (stdin).
tool_compress() {
    local level="$1" in_path="$2" out_path="$3"
    local engine
    engine="$(tool_engine)"
    if tool_is_adapter; then
        "$engine" compress --level "$level" "$in_path" "$out_path"
        return
    fi
    case "$TOOL" in
        gnu-gzip)
            if [[ "$in_path" == - ]]; then
                "$engine" -n "-$level" -c >"$out_path"
            else
                "$engine" -n "-$level" -c -- "$in_path" >"$out_path"
            fi
            ;;
        pigz)
            if [[ "$in_path" == - ]]; then
                "$engine" -p1 -n "-$level" -c >"$out_path"
            else
                "$engine" -p1 -n "-$level" -c -- "$in_path" >"$out_path"
            fi
            ;;
        libdeflate-gzip)
            if [[ "$in_path" == - ]]; then
                "$engine" "-$level" -k -c >"$out_path"
            else
                "$engine" "-$level" -k -c "$in_path" >"$out_path"
            fi
            ;;
        igzip)
            if [[ "$in_path" == - ]]; then
                "$engine" -n "-$level" -c >"$out_path"
            else
                "$engine" -n "-$level" -c "$in_path" >"$out_path"
            fi
            ;;
        zlib-ng)
            if [[ "$in_path" == - ]]; then
                "$engine" "-$level" -c >"$out_path"
            else
                "$engine" "-$level" -c "$in_path" >"$out_path"
            fi
            ;;
        *) return 64 ;;
    esac
}

# Write plaintext from IN to OUT. IN may be - (stdin).
tool_decompress() {
    local in_path="$1" out_path="$2"
    local engine
    engine="$(tool_engine)"
    if tool_is_adapter; then
        "$engine" decompress "$in_path" "$out_path"
        return
    fi
    case "$TOOL" in
        gnu-gzip)
            if [[ "$in_path" == - ]]; then
                "$engine" -d -c >"$out_path"
            else
                "$engine" -d -c -- "$in_path" >"$out_path"
            fi
            ;;
        pigz)
            if [[ "$in_path" == - ]]; then
                "$engine" -p1 -d -c >"$out_path"
            else
                "$engine" -p1 -d -c -- "$in_path" >"$out_path"
            fi
            ;;
        libdeflate-gzip)
            if [[ "$in_path" == - ]]; then
                "$engine" -d -k -c >"$out_path"
            else
                "$engine" -d -k -c "$in_path" >"$out_path"
            fi
            ;;
        igzip)
            if [[ "$in_path" == - ]]; then
                "$engine" -d -c >"$out_path"
            else
                "$engine" -d -c "$in_path" >"$out_path"
            fi
            ;;
        zlib-ng)
            if [[ "$in_path" == - ]]; then
                "$engine" -d -c >"$out_path"
            else
                "$engine" -d -c "$in_path" >"$out_path"
            fi
            ;;
        *) return 64 ;;
    esac
}

# Single Zebrac command string. Zebrac execs this program (no /bin/sh).
# Native CLIs write stdout; Zebrac already sinks the child's stdout.
zebrac_compress_cmd() {
    local level="$1" in_path="$2"
    local engine
    engine="$(tool_engine)"
    if tool_is_adapter; then
        printf '%s compress --level %s %s /dev/null\n' "$engine" "$level" "$in_path"
        return
    fi
    case "$TOOL" in
        gnu-gzip) printf '%s -n -%s -c %s\n' "$engine" "$level" "$in_path" ;;
        pigz) printf '%s -p1 -n -%s -c %s\n' "$engine" "$level" "$in_path" ;;
        libdeflate-gzip) printf '%s -%s -k -c %s\n' "$engine" "$level" "$in_path" ;;
        igzip) printf '%s -n -%s -c %s\n' "$engine" "$level" "$in_path" ;;
        zlib-ng) printf '%s -%s -c %s\n' "$engine" "$level" "$in_path" ;;
        *) return 64 ;;
    esac
}

zebrac_decompress_cmd() {
    local in_path="$1"
    local engine
    engine="$(tool_engine)"
    if tool_is_adapter; then
        printf '%s decompress %s /dev/null\n' "$engine" "$in_path"
        return
    fi
    case "$TOOL" in
        gnu-gzip) printf '%s -d -c %s\n' "$engine" "$in_path" ;;
        pigz) printf '%s -p1 -d -c %s\n' "$engine" "$in_path" ;;
        libdeflate-gzip) printf '%s -d -k -c %s\n' "$engine" "$in_path" ;;
        igzip) printf '%s -d -c %s\n' "$engine" "$in_path" ;;
        zlib-ng) printf '%s -d -c %s\n' "$engine" "$in_path" ;;
        *) return 64 ;;
    esac
}
