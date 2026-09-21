#!/usr/bin/env bash
# Build comparison tools into repository-local, ignored storage.
# C/host CLIs stay native programs. Zig supplies the standard-library and z-flate format adapters.
# Rust adapters are those languages' CLIs. Host gzip and pigz are not copied.
# libdeflate, ISA-L, and zlib-ng are built into tools/.local with a cmake
# prefix under /tmp/z-flate-tools.*. No global prefix. Local engines must not
# link Fedora libdeflate, ISA-L, or zlib.

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TOOLS_DIR/.." && pwd)"
LOCAL_DIR="$TOOLS_DIR/.local"
INSTALLS_DIR="$LOCAL_DIR/installs"
BIN_DIR="$TOOLS_DIR/bin"
TOOL_JOBS="${TOOL_JOBS:-2}"
KEEP_TOOL_WORK="${KEEP_TOOL_WORK:-0}"
REBUILD=0
ACTIVE_WORK=""
ACTIVE_STAGE=""

# shellcheck source=tools/versions.sh
source "$TOOLS_DIR/versions.sh"

PEERS=(std-gzip z-flate-gzip std-zlib z-flate-zlib system-zlib libdeflate-zlib gnu-gzip libdeflate-gzip igzip pigz flate2-miniz flate2-zlib-rs zlib-ng zlib-ng-zlib)
ALL_TARGETS=("${PEERS[@]}")

usage() {
    printf '%s\n' \
        'usage: tools/install.sh [NAME|all]' \
        '       tools/install.sh --rebuild [NAME|all]' \
        '       tools/install.sh --check [NAME|all]' \
        '       tools/install.sh --list' \
        '' \
        'names: std-gzip z-flate-gzip std-zlib z-flate-zlib system-zlib libdeflate-zlib gnu-gzip libdeflate-gzip igzip pigz flate2-miniz flate2-zlib-rs zlib-ng zlib-ng-zlib' \
        '' \
        'Linux x86_64 only. Host gzip and pigz stay at /usr/bin. libdeflate,' \
        'igzip, and zlib-ng are native CLIs under ignored tools/.local/. Zig' \
        'spawn wrappers around C CLIs are not used. TOOL_JOBS defaults to 2;' \
        'KEEP_TOOL_WORK=1 keeps /tmp work.'
}

cleanup() {
    if [[ -n "$ACTIVE_STAGE" && -d "$ACTIVE_STAGE" ]]; then
        case "$ACTIVE_STAGE" in
            "$LOCAL_DIR"/stage/*) rm -rf -- "$ACTIVE_STAGE" ;;
        esac
    fi
    if [[ -n "$ACTIVE_WORK" && -d "$ACTIVE_WORK" ]]; then
        case "$ACTIVE_WORK" in
            /tmp/z-flate-tools.*)
                if [[ "$KEEP_TOOL_WORK" == 1 ]]; then
                    printf 'keep: %s\n' "$ACTIVE_WORK"
                else
                    rm -rf -- "$ACTIVE_WORK"
                fi
                ;;
        esac
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_linux_x64() {
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
        printf 'error: tools/install.sh supports Linux x86_64 only\n' >&2
        return 1
    }
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: required host build command not found: %s\n' "$1" >&2
        return 1
    }
}

require_zig() {
    require_command zig
    local zig_bin
    zig_bin="$(command -v zig)"
    [[ "$(zig version)" == "$ZIG_VERSION" ]] || {
        printf 'error: adapters require Zig %s (got %s from %s)\n' \
            "$ZIG_VERSION" "$(zig version)" "$zig_bin" >&2
        return 1
    }
}

validate_settings() {
    [[ "$TOOL_JOBS" =~ ^[1-9][0-9]*$ ]] || {
        printf 'error: TOOL_JOBS must be a positive integer\n' >&2
        return 1
    }
    case "$KEEP_TOOL_WORK" in
        0 | 1) ;;
        *)
            printf 'error: KEEP_TOOL_WORK must be 0 or 1\n' >&2
            return 1
            ;;
    esac
}

version_for() {
    case "$1" in
        std-gzip) printf '%s\n' "$STD_GZIP_VERSION" ;;
        z-flate-gzip | z-flate-zlib) printf '%s\n' "$Z_FLATE_VERSION" ;;
        std-zlib) printf '%s\n' "$STD_ZLIB_VERSION" ;;
        system-zlib) printf '%s\n' "$SYSTEM_ZLIB_VERSION" ;;
        libdeflate-zlib) printf '%s\n' "$LIBDEFLATE_VERSION" ;;
        gnu-gzip) printf '%s\n' "$GNU_GZIP_VERSION" ;;
        pigz) printf '%s\n' "$PIGZ_VERSION" ;;
        libdeflate-gzip) printf '%s\n' "$LIBDEFLATE_VERSION" ;;
        igzip) printf '%s\n' "$ISAL_VERSION" ;;
        flate2-miniz) printf '%s\n' "$FLATE2_MINIZ_VERSION" ;;
        flate2-zlib-rs) printf '%s\n' "$FLATE2_ZLIB_RS_VERSION" ;;
        zlib-ng) printf '%s\n' "$ZLIB_NG_VERSION" ;;
        zlib-ng-zlib) printf '%s\n' "$ZLIB_NG_VERSION" ;;
        *) return 64 ;;
    esac
}

expand_target() {
    case "$1" in
        all | peers) printf '%s\n' "${ALL_TARGETS[@]}" ;;
        std-gzip | z-flate-gzip | std-zlib | z-flate-zlib | system-zlib | libdeflate-zlib | gnu-gzip | libdeflate-gzip | igzip | pigz | flate2-miniz | flate2-zlib-rs | zlib-ng | zlib-ng-zlib)
            printf '%s\n' "$1"
            ;;
        *)
            printf 'error: unknown target: %s\n' "$1" >&2
            return 64
            ;;
    esac
}

start_work() {
    if [[ -z "$ACTIVE_WORK" ]]; then
        ACTIVE_WORK="$(mktemp -d /tmp/z-flate-tools.XXXXXX)"
    fi
}

download_archive() {
    local url="$1" output="$2"
    require_command curl
    printf 'download: %s\n' "$url"
    curl --fail --location --retry 3 --show-error --silent "$url" --output "$output"
}

extract_archive() {
    local archive="$1" destination="$2"
    mkdir -p "$destination"
    tar -xzf "$archive" -C "$destination" --strip-components=1
}

switch_link() {
    local name="$1" version="$2"
    local link="$BIN_DIR/$name" temporary="$BIN_DIR/$name.tmp.$$"
    local target="../.local/installs/$name/$version/bin/$name"
    mkdir -p "$BIN_DIR"
    if [[ -e "$link" && ! -L "$link" ]]; then
        printf 'error: installer will not replace non-link path: %s\n' "$link" >&2
        return 1
    fi
    ln -s "$target" "$temporary"
    mv -Tf -- "$temporary" "$link"
}

switch_abs_link() {
    local name="$1" target="$2"
    local link="$BIN_DIR/$name" temporary="$BIN_DIR/$name.tmp.$$"
    mkdir -p "$BIN_DIR"
    if [[ -e "$link" && ! -L "$link" ]]; then
        printf 'error: installer will not replace non-link path: %s\n' "$link" >&2
        return 1
    fi
    ln -s "$target" "$temporary"
    mv -Tf -- "$temporary" "$link"
}

remove_bin_link() {
    local name="$1"
    local link="$BIN_DIR/$name"
    if [[ -L "$link" ]]; then
        rm -f -- "$link"
    elif [[ -e "$link" ]]; then
        printf 'error: installer will not remove non-link path: %s\n' "$link" >&2
        return 1
    fi
}

host_version() {
    case "$1" in
        gnu-gzip)
            "$GNU_GZIP_BIN" --version | awk 'NR==1{print $2}'
            ;;
        pigz)
            "$PIGZ_BIN" --version | awk '{print $2; exit}'
            ;;
        *) return 1 ;;
    esac
}

write_receipt() {
    local dest="$1" name="$2" version="$3" source="$4" compiler="$5" build_profile="$6"
    local suite_commit suite_dirty
    suite_commit="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || printf unknown)"
    if git -C "$ROOT_DIR" rev-parse HEAD >/dev/null 2>&1 &&
        [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
        suite_dirty=true
    else
        suite_dirty=false
    fi
    {
        printf 'schema\tz-flate-tool-receipt-v1\n'
        printf 'name\t%s\nversion\t%s\nsource\t%s\n' "$name" "$version" "$source"
        printf 'compiler\t%s\njobs\t%s\n' "$compiler" "$TOOL_JOBS"
        printf 'build_profile\t%s\n' "$build_profile"
        printf 'suite_commit\t%s\nsuite_dirty\t%s\n' "$suite_commit" "$suite_dirty"
    } >"$dest"
}

publish() {
    local name="$1" version="$2" binary="$3" source="$4" compiler="$5" build_profile="$6"
    local destination="$INSTALLS_DIR/$name/$version"
    mkdir -p "$LOCAL_DIR/stage" "$INSTALLS_DIR/$name"
    ACTIVE_STAGE="$(mktemp -d "$LOCAL_DIR/stage/$name.XXXXXX")"
    mkdir -p "$ACTIVE_STAGE/bin"
    install -m 755 "$binary" "$ACTIVE_STAGE/bin/$name"
    if command -v strip >/dev/null 2>&1; then
        strip --strip-unneeded "$ACTIVE_STAGE/bin/$name" 2>/dev/null || true
    fi
    write_receipt "$ACTIVE_STAGE/receipt.tsv" "$name" "$version" "$source" "$compiler" "$build_profile"
    if [[ -d "$destination" ]]; then
        case "$destination" in
            "$INSTALLS_DIR"/*/*) rm -rf -- "$destination" ;;
            *)
                printf 'error: invalid rebuild path: %s\n' "$destination" >&2
                return 1
                ;;
        esac
    fi
    mv "$ACTIVE_STAGE" "$destination"
    ACTIVE_STAGE=""
    switch_link "$name" "$version"
    printf 'installed: %s %s\n' "$name" "$version"
}

publish_host() {
    local name="$1" version="$2" host_bin="$3" source="$4" compiler="$5" build_profile="$6"
    local destination="$INSTALLS_DIR/$name/$version"
    mkdir -p "$LOCAL_DIR/stage" "$INSTALLS_DIR/$name"
    ACTIVE_STAGE="$(mktemp -d "$LOCAL_DIR/stage/$name.XXXXXX")"
    write_receipt "$ACTIVE_STAGE/receipt.tsv" "$name" "$version" "$source" "$compiler" "$build_profile"
    if [[ -d "$destination" ]]; then
        case "$destination" in
            "$INSTALLS_DIR"/*/*) rm -rf -- "$destination" ;;
            *)
                printf 'error: invalid rebuild path: %s\n' "$destination" >&2
                return 1
                ;;
        esac
    fi
    mv "$ACTIVE_STAGE" "$destination"
    ACTIVE_STAGE=""
    if [[ -n "$host_bin" ]]; then
        switch_abs_link "$name" "$host_bin"
    else
        remove_bin_link "$name"
    fi
    printf 'installed: %s %s\n' "$name" "$version"
}

check_target() {
    local name="$1" version path receipt resolved_bin resolved_host
    version="$(version_for "$name")"
    receipt="$INSTALLS_DIR/$name/$version/receipt.tsv"
    path="$INSTALLS_DIR/$name/$version/bin/$name"
    if [[ ! -f "$receipt" ]]; then
        printf 'missing: %s %s\n' "$name" "$version" >&2
        return 1
    fi
    grep -Fqx "schema"$'\t'"z-flate-tool-receipt-v1" "$receipt" || return 1
    grep -Fqx "version"$'\t'"$version" "$receipt" || return 1
    case "$name" in
        gnu-gzip)
            [[ -x "$GNU_GZIP_BIN" ]] || {
                printf 'error: host gzip missing: %s\n' "$GNU_GZIP_BIN" >&2
                return 1
            }
            [[ "$(host_version gnu-gzip)" == "$GNU_GZIP_VERSION" ]] || {
                printf 'error: host gzip version %s, pin is %s\n' \
                    "$(host_version gnu-gzip)" "$GNU_GZIP_VERSION" >&2
                return 1
            }
            [[ -L "$BIN_DIR/gnu-gzip" ]] || {
                printf 'error: missing host link: %s\n' "$BIN_DIR/gnu-gzip" >&2
                return 1
            }
            resolved_bin="$(readlink -f "$BIN_DIR/gnu-gzip")"
            resolved_host="$(readlink -f "$GNU_GZIP_BIN")"
            [[ "$resolved_bin" == "$resolved_host" ]] || {
                printf 'error: %s must be a symlink to %s\n' \
                    "$BIN_DIR/gnu-gzip" "$GNU_GZIP_BIN" >&2
                return 1
            }
            ;;
        pigz)
            [[ -x "$PIGZ_BIN" ]] || {
                printf 'error: host pigz missing: %s\n' "$PIGZ_BIN" >&2
                return 1
            }
            [[ "$(host_version pigz)" == "$PIGZ_VERSION" ]] || {
                printf 'error: host pigz version %s, pin is %s\n' \
                    "$(host_version pigz)" "$PIGZ_VERSION" >&2
                return 1
            }
            if [[ -e "$BIN_DIR/pigz" ]]; then
                printf 'error: pigz is invoked as %s -p1; do not publish %s\n' \
                    "$PIGZ_BIN" "$BIN_DIR/pigz" >&2
                return 1
            fi
            ;;
        libdeflate-gzip)
            [[ -x "$path" ]] || {
                printf 'missing: %s %s\n' "$name" "$version" >&2
                return 1
            }
            file -b "$path" | grep -q 'statically linked' && {
                printf 'error: %s is a Zig wrapper, not the native CLI\n' "$path" >&2
                return 1
            }
            "$path" -V | grep -Fq "$version" || return 1
            assert_not_linked "$path" 'libdeflate|libisal|libigzip' "$name" || return 1
            ;;
        libdeflate-zlib)
            [[ -x "$path" ]] || {
                printf 'missing: %s %s\n' "$name" "$version" >&2
                return 1
            }
            "$path" --version | grep -Fq "$version" || return 1
            assert_not_linked "$path" 'libz\.so|libdeflate|libisal|libigzip' "$name" || return 1
            ;;
        igzip)
            [[ -x "$path" ]] || {
                printf 'missing: %s %s\n' "$name" "$version" >&2
                return 1
            }
            file -b "$path" | grep -q 'statically linked' && {
                printf 'error: %s is a Zig wrapper, not the native CLI\n' "$path" >&2
                return 1
            }
            "$path" --version | grep -Fq 'unknown version' || return 1
            assert_not_linked "$path" 'libdeflate|libisal|libigzip' "$name" || return 1
            ;;
        std-gzip | z-flate-gzip | std-zlib | z-flate-zlib | flate2-miniz | flate2-zlib-rs)
            [[ -x "$path" ]] || {
                printf 'missing: %s %s\n' "$name" "$version" >&2
                return 1
            }
            "$path" --version | grep -Fq "$version" || return 1
            case "$name" in
                flate2-miniz | flate2-zlib-rs)
                    assert_not_linked "$path" 'libz\.so|libminiz|libdeflate' "$name" || return 1
                    ;;
            esac
            ;;
        system-zlib)
            [[ -x "$path" ]] || {
                printf 'missing: %s %s\n' "$name" "$version" >&2
                return 1
            }
            "$path" --version | grep -Fq "$version" || return 1
            ldd "$path" 2>/dev/null | grep -Eq 'libz\.so' || {
                printf 'error: %s is not using the host libz\n' "$path" >&2
                return 1
            }
            ;;
        zlib-ng)
            [[ -x "$path" ]] || {
                printf 'missing: %s %s\n' "$name" "$version" >&2
                return 1
            }
            file -b "$path" | grep -q 'statically linked' && {
                printf 'error: %s is a Zig wrapper, not the native CLI\n' "$path" >&2
                return 1
            }
            "$path" --help | grep -Fq 'Usage: minigzip' || return 1
            assert_not_linked "$path" 'libz\.so|libdeflate|libisal' "$name" || return 1
            ;;
        zlib-ng-zlib)
            [[ -x "$path" ]] || {
                printf 'missing: %s %s\n' "$name" "$version" >&2
                return 1
            }
            "$path" --version | grep -Fq "$version" || return 1
            assert_not_linked "$path" 'libz\.so|libdeflate|libisal' "$name" || return 1
            ;;
        *) return 64 ;;
    esac
    printf 'ok: %s %s\n' "$name" "$version"
}

assert_not_linked() {
    local binary="$1" pattern="$2" label="$3" deps
    deps="$(ldd "$binary" 2>/dev/null || true)"
    if printf '%s\n' "$deps" | grep -Eq "$pattern"; then
        printf 'error: %s links a forbidden library (%s):\n%s\n' \
            "$label" "$pattern" "$deps" >&2
        return 1
    fi
}

already_installed() {
    check_target "$1" >/dev/null 2>&1
}

build_std_gzip() {
    local work
    require_zig
    start_work
    work="$ACTIVE_WORK/std-gzip"
    mkdir -p "$work/global-cache" "$work/local-cache" "$work/prefix"
    printf 'build: std.compress.flate gzip adapter\n'
    ZIG_GLOBAL_CACHE_DIR="$work/global-cache" ZIG_LOCAL_CACHE_DIR="$work/local-cache" \
        zig build --build-file "$TOOLS_DIR/build.zig" -Dadapter=std-gzip \
        -Doptimize=ReleaseFast -Dstrip=true -Dcpu=native \
        --prefix "$work/prefix" -j"$TOOL_JOBS"
    publish std-gzip "$STD_GZIP_VERSION" "$work/prefix/bin/std-gzip" \
        "Zig ${ZIG_VERSION} standard library" "$(zig version)" \
        'ReleaseFast;strip;single_threaded;cpu=native;x86_64-linux'
}

build_std_zlib() {
    local work
    require_zig
    start_work
    work="$ACTIVE_WORK/std-zlib"
    mkdir -p "$work/global-cache" "$work/local-cache" "$work/prefix"
    printf 'build: std.compress.flate zlib adapter\n'
    ZIG_GLOBAL_CACHE_DIR="$work/global-cache" ZIG_LOCAL_CACHE_DIR="$work/local-cache" \
        zig build --build-file "$TOOLS_DIR/build.zig" -Dadapter=std-zlib \
        -Doptimize=ReleaseFast -Dstrip=true -Dcpu=native \
        --prefix "$work/prefix" -j"$TOOL_JOBS"
    publish std-zlib "$STD_ZLIB_VERSION" "$work/prefix/bin/std-zlib" \
        "Zig ${ZIG_VERSION} standard library" "$(zig version)" \
        'ReleaseFast;strip;single_threaded;cpu=native;x86_64-linux'
}

build_z_flate() {
    local name="$1" format="$2" work
    require_zig
    start_work
    work="$ACTIVE_WORK/$name"
    mkdir -p "$work/global-cache" "$work/local-cache" "$work/prefix"
    printf 'build: z-flate %s adapter\n' "$format"
    ZIG_GLOBAL_CACHE_DIR="$work/global-cache" ZIG_LOCAL_CACHE_DIR="$work/local-cache" \
        zig build --build-file "$TOOLS_DIR/build.zig" -Dadapter="$name" \
        -Doptimize=ReleaseFast -Dstrip=true -Dcpu=native \
        --prefix "$work/prefix" -j"$TOOL_JOBS"
    publish "$name" "$Z_FLATE_VERSION" "$work/prefix/bin/$name" \
        "local z-flate src/root.zig $format adapter" "$(zig version)" \
        "ReleaseFast;strip;single_threaded;cpu=native;x86_64-linux;$format"
}

build_system_zlib() {
    local work
    require_command cc
    start_work
    work="$ACTIVE_WORK/system-zlib"
    mkdir -p "$work"
    printf 'build: system libz %s zlib API\n' "$SYSTEM_ZLIB_VERSION"
    cc -O3 -DNDEBUG -march=native -std=c11 \
        "$TOOLS_DIR/c/zlib_adapter.c" -lz -o "$work/system-zlib"
    publish system-zlib "$SYSTEM_ZLIB_VERSION" "$work/system-zlib" \
        'host system libz' "$(cc --version | awk 'NR==1{print $1, $NF}')" \
        'Release;dynamic;zlib-api;ST;march=native'
}

prepare_libdeflate() {
    local need_gzip="${1:-0}" work archive source build_gzip
    require_command cmake
    start_work
    work="$ACTIVE_WORK/libdeflate"
    archive="$work/libdeflate.tar.gz"
    source="$work/source"
    build_gzip=OFF
    if [[ "$need_gzip" == 1 ]]; then
        build_gzip=ON
    fi
    mkdir -p "$work/build" "$work/prefix"
    if [[ ! -f "$work/prefix/include/libdeflate.h" ||
        ( ! -f "$work/prefix/lib/libdeflate.a" && ! -f "$work/prefix/lib64/libdeflate.a" ) ||
        ( "$need_gzip" == 1 && ! -x "$work/prefix/bin/libdeflate-gzip" ) ]]; then
        if [[ ! -f "$archive" ]]; then
            download_archive "$LIBDEFLATE_URL" "$archive"
        fi
        if [[ ! -f "$source/CMakeLists.txt" ]]; then
            extract_archive "$archive" "$source"
        fi
        printf 'build: libdeflate %s static library (gzip CLI=%s)\n' "$LIBDEFLATE_VERSION" "$build_gzip"
        cmake -S "$source" -B "$work/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$work/prefix" \
            -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=native" \
            -DLIBDEFLATE_BUILD_SHARED_LIB=OFF \
            -DLIBDEFLATE_BUILD_STATIC_LIB=ON \
            -DLIBDEFLATE_BUILD_GZIP="$build_gzip" \
            -DLIBDEFLATE_USE_SHARED_LIB=OFF \
            -DLIBDEFLATE_BUILD_TESTS=OFF \
            -DCMAKE_INSTALL_MESSAGE=NEVER
        cmake --build "$work/build" -j"$TOOL_JOBS"
        cmake --install "$work/build"
    fi
    [[ -f "$work/prefix/lib/libdeflate.a" || -f "$work/prefix/lib64/libdeflate.a" ]] || {
        printf 'error: libdeflate static library missing after install\n' >&2
        return 1
    }
    if [[ "$need_gzip" == 1 && ! -x "$work/prefix/bin/libdeflate-gzip" ]]; then
        printf 'error: libdeflate-gzip missing after install\n' >&2
        return 1
    fi
}

build_gnu_gzip() {
    [[ -x "$GNU_GZIP_BIN" ]] || {
        printf 'error: host gzip not found: %s\n' "$GNU_GZIP_BIN" >&2
        return 1
    }
    [[ "$(host_version gnu-gzip)" == "$GNU_GZIP_VERSION" ]] || {
        printf 'error: host gzip version %s, pin is %s\n' \
            "$(host_version gnu-gzip)" "$GNU_GZIP_VERSION" >&2
        return 1
    }
    publish_host gnu-gzip "$GNU_GZIP_VERSION" "$GNU_GZIP_BIN" \
        "host ${GNU_GZIP_BIN}" "host gzip $(host_version gnu-gzip)" \
        'host-native;ST;-n;levels-1-6-9'
}

build_pigz() {
    [[ -x "$PIGZ_BIN" ]] || {
        printf 'error: host pigz not found: %s\n' "$PIGZ_BIN" >&2
        return 1
    }
    [[ "$(host_version pigz)" == "$PIGZ_VERSION" ]] || {
        printf 'error: host pigz version %s, pin is %s\n' \
            "$(host_version pigz)" "$PIGZ_VERSION" >&2
        return 1
    }
    publish_host pigz "$PIGZ_VERSION" "" \
        "host ${PIGZ_BIN} -p1" "host pigz $(host_version pigz)" \
        'host-native;ST;-p1;-n;levels-1-6-9'
}

build_libdeflate_gzip() {
    local work
    prepare_libdeflate 1
    work="$ACTIVE_WORK/libdeflate"
    [[ -x "$work/prefix/bin/libdeflate-gzip" ]] || {
        printf 'error: libdeflate-gzip missing after install\n' >&2
        return 1
    }
    publish libdeflate-gzip "$LIBDEFLATE_VERSION" "$work/prefix/bin/libdeflate-gzip" \
        "$LIBDEFLATE_URL" "cmake $(cmake --version | awk 'NR==1{print $3}')" \
        'Release;static;gzip-cli;ST;march=native;native-cli'
}

build_libdeflate_zlib() {
    local work lib include_dir
    require_command cc
    prepare_libdeflate 0
    work="$ACTIVE_WORK/libdeflate"
    lib="$(find "$work/prefix" -type f -name 'libdeflate.a' -print -quit)"
    include_dir="$work/prefix/include"
    [[ -n "$lib" && -f "$include_dir/libdeflate.h" ]] || {
        printf 'error: libdeflate headers or static library missing\n' >&2
        return 1
    }
    printf 'build: libdeflate %s zlib full-buffer adapter\n' "$LIBDEFLATE_VERSION"
    cc -O3 -DNDEBUG -march=native -std=c11 -I"$include_dir" \
        "$TOOLS_DIR/c/libdeflate_zlib_adapter.c" "$lib" -o "$work/libdeflate-zlib"
    publish libdeflate-zlib "$LIBDEFLATE_VERSION" "$work/libdeflate-zlib" \
        "$LIBDEFLATE_URL" "cc $(cc --version | awk 'NR==1{print $1, $NF}')" \
        'Release;static;libdeflate-zlib;full-buffer;known-output-size;ST;march=native'
}

build_igzip() {
    local work archive source engine
    engine="$INSTALLS_DIR/igzip/$ISAL_VERSION/libexec/igzip"
    if [[ "$REBUILD" != 1 && -x "$engine" ]]; then
        printf 'reuse: local igzip engine\n'
        publish igzip "$ISAL_VERSION" "$engine" \
            "$ISAL_URL" 'previously built local CLI' \
            'Release;static;igzip-cli;ST;no-shim;native-cli'
        return
    fi
    require_command cmake
    require_command nasm
    start_work
    work="$ACTIVE_WORK/isal"
    archive="$work/isal.tar.gz"
    source="$work/source"
    mkdir -p "$work/build" "$work/prefix"
    download_archive "$ISAL_URL" "$archive"
    extract_archive "$archive" "$source"
    printf 'build: ISA-L %s igzip CLI (static, no shim, no -T)\n' "$ISAL_VERSION"
    cmake -S "$source" -B "$work/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$work/prefix" \
        -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=native" \
        -DCMAKE_ASM_NASM_COMPILER="$(command -v nasm)" \
        -DBUILD_SHARED_LIBS=OFF \
        -DISAL_BUILD_TESTS=OFF \
        -DISAL_BUILD_PERF_TESTS=OFF \
        -DISAL_BUILD_FUZZ_TESTS=OFF \
        -DISAL_BUILD_ISAL_SHIM=OFF \
        -DISAL_BUILD_IGZIP_CLI=ON \
        -DCMAKE_INSTALL_MESSAGE=NEVER
    cmake --build "$work/build" -j"$TOOL_JOBS"
    cmake --install "$work/build"
    [[ -x "$work/prefix/bin/igzip" ]] || {
        printf 'error: igzip missing after install\n' >&2
        return 1
    }
    publish igzip "$ISAL_VERSION" "$work/prefix/bin/igzip" \
        "$ISAL_URL" "cmake $(cmake --version | awk 'NR==1{print $3}'); nasm $(nasm -v | awk '{print $3}')" \
        'Release;static;igzip-cli;ST;no-shim;march=native;native-cli'
}

build_flate2_miniz() {
    local work output
    require_command cargo
    require_command rustc
    start_work
    work="$ACTIVE_WORK/flate2-miniz"
    mkdir -p "$work/cargo-home" "$work/target"
    printf 'build: flate2 %s rust_backend (miniz_oxide)\n' "$FLATE2_MINIZ_VERSION"
    CARGO_HOME="$work/cargo-home" CARGO_TARGET_DIR="$work/target" \
        RUSTFLAGS='-C target-cpu=native' \
        cargo build --locked --release \
        --manifest-path "$TOOLS_DIR/rust/flate2-miniz/Cargo.toml" \
        -j "$TOOL_JOBS"
    output="$work/target/release/flate2-miniz"
    publish flate2-miniz "$FLATE2_MINIZ_VERSION" "$output" \
        'crates.io flate2 rust_backend via tracked Cargo.lock' \
        "$(rustc --version)" \
        'cargo-release;rust_backend;target-cpu=native;ST'
}

build_flate2_zlib_rs() {
    local work output
    require_command cargo
    require_command rustc
    start_work
    work="$ACTIVE_WORK/flate2-zlib-rs"
    mkdir -p "$work/cargo-home" "$work/target"
    printf 'build: flate2 %s zlib-rs %s\n' "$FLATE2_ZLIB_RS_VERSION" "$ZLIB_RS_VERSION"
    CARGO_HOME="$work/cargo-home" CARGO_TARGET_DIR="$work/target" \
        RUSTFLAGS='-C target-cpu=native' \
        cargo build --locked --release \
        --manifest-path "$TOOLS_DIR/rust/flate2-zlib-rs/Cargo.toml" \
        -j "$TOOL_JOBS"
    output="$work/target/release/flate2-zlib-rs"
    publish flate2-zlib-rs "$FLATE2_ZLIB_RS_VERSION" "$output" \
        "crates.io flate2 zlib-rs ${ZLIB_RS_VERSION} via tracked Cargo.lock" \
        "$(rustc --version)" \
        'cargo-release;zlib-rs;target-cpu=native;ST'
}

build_zlib_ng() {
    local work archive source engine
    engine="$INSTALLS_DIR/zlib-ng/$ZLIB_NG_VERSION/libexec/zlib-ng"
    if [[ "$REBUILD" != 1 && -x "$engine" ]]; then
        printf 'reuse: local zlib-ng minigzip\n'
        publish zlib-ng "$ZLIB_NG_VERSION" "$engine" \
            "$ZLIB_NG_URL" 'previously built local CLI' \
            'Release;static;minigzip;ST;native-cli'
        return
    fi
    require_command cmake
    start_work
    work="$ACTIVE_WORK/zlib-ng"
    archive="$work/zlib-ng.tar.gz"
    source="$work/source"
    mkdir -p "$work/build" "$work/prefix"
    download_archive "$ZLIB_NG_URL" "$archive"
    extract_archive "$archive" "$source"
    printf 'build: zlib-ng %s minigzip (static, local prefix)\n' "$ZLIB_NG_VERSION"
    cmake -S "$source" -B "$work/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$work/prefix" \
        -DBUILD_SHARED_LIBS=OFF \
        -DZLIB_COMPAT=OFF \
        -DWITH_GTEST=OFF \
        -DWITH_FUZZERS=OFF \
        -DWITH_BENCHMARKS=OFF \
        -DBUILD_TESTING=ON \
        -DINSTALL_UTILS=ON \
        -DWITH_NATIVE_INSTRUCTIONS=ON \
        -DCMAKE_INSTALL_MESSAGE=NEVER
    cmake --build "$work/build" -j"$TOOL_JOBS"
    cmake --install "$work/build"
    [[ -x "$work/prefix/bin/minigzip" ]] || {
        printf 'error: zlib-ng minigzip missing after install\n' >&2
        return 1
    }
    publish zlib-ng "$ZLIB_NG_VERSION" "$work/prefix/bin/minigzip" \
        "$ZLIB_NG_URL" "cmake $(cmake --version | awk 'NR==1{print $3}')" \
        'Release;static;minigzip;ST;WITH_NATIVE_INSTRUCTIONS;native-cli'
}

build_zlib_ng_zlib() {
    local work archive source lib
    require_command cmake
    start_work
    work="$ACTIVE_WORK/zlib-ng-zlib"
    archive="$work/zlib-ng.tar.gz"
    source="$work/source"
    mkdir -p "$work/build" "$work/prefix"
    download_archive "$ZLIB_NG_URL" "$archive"
    extract_archive "$archive" "$source"
    printf 'build: zlib-ng %s native zlib API (static, no new strategies)\n' "$ZLIB_NG_VERSION"
    cmake -S "$source" -B "$work/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$work/prefix" \
        -DBUILD_SHARED_LIBS=OFF \
        -DZLIB_COMPAT=OFF \
        -DWITH_GTEST=OFF \
        -DWITH_FUZZERS=OFF \
        -DWITH_BENCHMARKS=OFF \
        -DBUILD_TESTING=OFF \
        -DINSTALL_UTILS=OFF \
        -DWITH_NATIVE_INSTRUCTIONS=ON \
        -DWITH_RUNTIME_CPU_DETECTION=OFF \
        -DWITH_NEW_STRATEGIES=OFF \
        -DCMAKE_INSTALL_MESSAGE=NEVER
    cmake --build "$work/build" -j"$TOOL_JOBS"
    cmake --install "$work/build"
    lib="$(find "$work/prefix" -type f \( -name 'libz-ng.a' -o -name 'libz.a' \) -print -quit)"
    [[ -n "$lib" ]] || {
        printf 'error: zlib-ng native static library missing after install\n' >&2
        return 1
    }
    cc -O3 -DNDEBUG -march=native -std=c11 \
        -DZIPIR_ZLIB_NG_NATIVE -I"$work/prefix/include" \
        "$TOOLS_DIR/c/zlib_adapter.c" "$lib" -o "$work/zlib-ng-zlib"
    publish zlib-ng-zlib "$ZLIB_NG_VERSION" "$work/zlib-ng-zlib" \
        "$ZLIB_NG_URL" "$(cc --version | awk 'NR==1{print $1, $NF}')" \
        'Release;static;zlib-ng-native-api;WITH_NATIVE_INSTRUCTIONS;NO_NEW_STRATEGIES;ST;march=native'
}

install_target() {
    local name="$1"
    if [[ "$REBUILD" != 1 ]] && already_installed "$name"; then
        case "$name" in
            gnu-gzip) switch_abs_link gnu-gzip "$GNU_GZIP_BIN" ;;
            pigz) remove_bin_link pigz ;;
            *) switch_link "$name" "$(version_for "$name")" ;;
        esac
        check_target "$name"
        return
    fi
    case "$name" in
        std-gzip) build_std_gzip ;;
        std-zlib) build_std_zlib ;;
        z-flate-gzip | z-flate-zlib) build_z_flate "$name" "${name#z-flate-}" ;;
        system-zlib) build_system_zlib ;;
        libdeflate-zlib) build_libdeflate_zlib ;;
        gnu-gzip) build_gnu_gzip ;;
        pigz) build_pigz ;;
        libdeflate-gzip) build_libdeflate_gzip ;;
        igzip) build_igzip ;;
        flate2-miniz) build_flate2_miniz ;;
        flate2-zlib-rs) build_flate2_zlib_rs ;;
        zlib-ng) build_zlib_ng ;;
        zlib-ng-zlib) build_zlib_ng_zlib ;;
        *) return 64 ;;
    esac
    check_target "$name"
}

list_targets() {
    local name version state
    for name in "${ALL_TARGETS[@]}"; do
        version="$(version_for "$name")"
        if check_target "$name" >/dev/null 2>&1; then
            state=installed
        else
            state=missing
        fi
        printf '%-16s %-12s %s\n' "$name" "$version" "$state"
    done
}

main() {
    local mode=install selection=all name
    require_linux_x64
    validate_settings
    case "${1:-}" in
        --help | -h)
            usage
            return
            ;;
        --list)
            list_targets
            return
            ;;
        --rebuild)
            REBUILD=1
            selection="${2:-all}"
            [[ $# -le 2 ]] || {
                usage >&2
                return 64
            }
            ;;
        --check)
            mode=check
            selection="${2:-all}"
            [[ $# -le 2 ]] || {
                usage >&2
                return 64
            }
            ;;
        '') ;;
        *)
            selection="$1"
            [[ $# -eq 1 ]] || {
                usage >&2
                return 64
            }
            ;;
    esac
    while IFS= read -r name; do
        if [[ "$mode" == check ]]; then
            check_target "$name"
        else
            install_target "$name"
        fi
    done < <(expand_target "$selection")
}

main "$@"
