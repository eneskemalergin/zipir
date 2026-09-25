#!/usr/bin/env bash
# Build or link the comparison peers and the bgzip BGZF oracle into ignored tools/.local/installs
# and tools/bin. C and host CLIs stay native programs; Zig and Rust adapters use the path CLI.
# Host gzip and pigz are not copied. Source builds use a /tmp/zipir-tools.* work directory and
# never a global prefix; native engines must not link Fedora libdeflate, ISA-L, or zlib.

set -euo pipefail
# shellcheck source=tools/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
TOOL_JOBS="${TOOL_JOBS:-2}"
REBUILD=0
STAGE=""
ORACLES=(bgzip)
ALL_TARGETS=("${PEER_TOOLS[@]}" "${ORACLES[@]}")

usage() {
    printf '%s\n' \
        'usage: tools/install.sh [--rebuild | --check] [NAME|prime|extended|all]' \
        '       tools/install.sh --list' \
        '' \
        "names: ${ALL_TARGETS[*]}" \
        'prime and extended are the tools/peers.tsv tiers plus the oracles; all is every target.' \
        '' \
        'Linux x86_64 only. Host gzip and pigz stay at /usr/bin. libdeflate, igzip, and zlib-ng' \
        'are native CLIs under ignored tools/.local/. TOOL_JOBS defaults to 2; KEEP_TOOL_WORK=1' \
        'keeps the /tmp work directory.'
}

cleanup_extra() {
    if [[ -n "$STAGE" && -d "$STAGE" && "$STAGE" == "$LOCAL_DIR"/stage/* ]]; then rm -rf -- "$STAGE"; fi
}

require_zig() {
    require_command zig
    [[ "$(zig version)" == "$ZIG_VERSION" ]] ||
        die "adapters require Zig $ZIG_VERSION (got $(zig version) from $(command -v zig))"
}

expand_target() {
    case "$1" in
        all | peers) printf '%s\n' "${ALL_TARGETS[@]}" ;;
        prime | extended)
            PEER_SET="$1" selected_tools
            printf '%s\n' "${ORACLES[@]}"
            ;;
        *)
            [[ " ${ALL_TARGETS[*]} " == *" $1 "* ]] || usage_error "unknown target: $1"
            printf '%s\n' "$1"
            ;;
    esac
}

fetch_source() {
    local url="$1" dest="$2" archive="$2.archive"
    [[ -d "$dest" ]] && return 0
    require_command curl
    mkdir -p "$dest.part"
    printf 'download: %s\n' "$url"
    curl --fail --location --retry 3 --show-error --silent "$url" --output "$archive"
    tar -xf "$archive" -C "$dest.part" --strip-components=1
    mv -- "$dest.part" "$dest"
}

# cmake_install SOURCE BUILD PREFIX ARGS...: Release build installed into PREFIX.
cmake_install() {
    local source="$1" build="$2" prefix="$3"
    shift 3
    require_command cmake
    cmake -S "$source" -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_INSTALL_MESSAGE=NEVER "$@"
    cmake --build "$build" -j"$TOOL_JOBS"
    cmake --install "$build"
}

# Newest mtime (seconds) of the sources a Zig adapter is built from. No digest: an adapter is
# stale when any of these files is newer than the build that the receipt records.
zig_source_mtime() {
    local sources=("$TOOLS_DIR/build.zig" "$TOOLS_DIR/build.zig.zon" "$TOOLS_DIR/zig")
    [[ "$1" != zipir-* ]] || sources+=("$ROOT_DIR/src" "$ROOT_DIR/build.zig" "$ROOT_DIR/build.zig.zon")
    find "${sources[@]}" -type f -printf '%T@\n' | sort -n | tail -1 | cut -d. -f1
}

cc_version() {
    cc --version | awk 'NR==1{print $1, $NF}'
}

# Points tools/bin/NAME at TARGET; an empty TARGET removes the link.
link_bin() {
    local link="$BIN_DIR/$1" target="$2"
    mkdir -p "$BIN_DIR"
    [[ ! -e "$link" || -L "$link" ]] || die "installer will not replace non-link path: $link"
    if [[ -z "$target" ]]; then
        rm -f -- "$link"
    else
        ln -s "$target" "$link.tmp.$$"
        mv -Tf -- "$link.tmp.$$" "$link"
    fi
}

bin_target() {
    case "$1" in
        gnu-gzip) printf '%s\n' "$GNU_GZIP_BIN" ;;
        pigz) ;; # invoked as /usr/bin/pigz -p1; never published under tools/bin
        *) printf '../.local/installs/%s/%s/bin/%s\n' "$1" "$(version_for "$1")" "$1" ;;
    esac
}

# publish NAME BINARY SOURCE COMPILER PROFILE: installs BINARY (empty for host tools) with a receipt.
publish() {
    local name="$1" binary="$2" source="$3" compiler="$4" profile="$5" version dest
    version="$(version_for "$name")"
    dest="$INSTALLS_DIR/$name/$version"
    mkdir -p "$LOCAL_DIR/stage" "$INSTALLS_DIR/$name"
    STAGE="$(mktemp -d "$LOCAL_DIR/stage/$name.XXXXXX")"
    if [[ -n "$binary" ]]; then
        install -D -m 755 "$binary" "$STAGE/bin/$name"
        strip --strip-unneeded "$STAGE/bin/$name" 2>/dev/null || true
    fi
    {
        printf 'schema\tzipir-tool-receipt-v1\n'
        printf 'name\t%s\nversion\t%s\nsource\t%s\n' "$name" "$version" "$source"
        printf 'compiler\t%s\njobs\t%s\nbuild_profile\t%s\n' "$compiler" "$TOOL_JOBS" "$profile"
        git_state | sed 's/^commit/suite_commit/; s/^dirty/suite_dirty/'
        if [[ "$name" =~ ^(std|zipir)- ]]; then printf 'source_mtime\t%s\n' "$(zig_source_mtime "$name")"; fi
    } >"$STAGE/receipt.tsv"
    [[ "$dest" == "$INSTALLS_DIR"/*/* ]] || die "invalid install path: $dest"
    rm -rf -- "$dest"
    mv "$STAGE" "$dest"
    STAGE=""
    link_bin "$name" "$(bin_target "$name")"
    printf 'installed: %s %s\n' "$name" "$version"
}

assert_links() {
    local binary="$1" forbidden="$2" deps
    deps="$(ldd "$binary" 2>/dev/null || true)"
    if [[ -n "$forbidden" ]] && grep -Eq "$forbidden" <<<"$deps"; then
        printf 'error: %s links a forbidden library (%s):\n%s\n' "$binary" "$forbidden" "$deps" >&2
        return 1
    fi
}

check_target() {
    local name="$1" version path forbidden=""
    version="$(version_for "$name")"
    path="$INSTALLS_DIR/$name/$version/bin/$name"
    [[ -f "$INSTALLS_DIR/$name/$version/receipt.tsv" ]] || {
        printf 'missing: %s %s\n' "$name" "$version" >&2
        return 1
    }
    grep -Fqx $'schema\tzipir-tool-receipt-v1' "$INSTALLS_DIR/$name/$version/receipt.tsv" || return 1
    grep -Fqx "version"$'\t'"$version" "$INSTALLS_DIR/$name/$version/receipt.tsv" || return 1
    case "$name" in
        gnu-gzip | pigz)
            path="$(tool_path "$name")"
            [[ -x "$path" ]] || { printf 'error: host %s missing: %s\n' "$name" "$path" >&2 && return 1; }
            [[ "$(tool_version_text "$name")" == "$version" ]] ||
                { printf 'error: host %s is %s, pin is %s\n' "$name" "$(tool_version_text "$name")" "$version" >&2 && return 1; }
            if [[ "$name" == gnu-gzip ]]; then
                [[ "$(readlink -f "$BIN_DIR/gnu-gzip")" == "$(readlink -f "$GNU_GZIP_BIN")" ]] ||
                    { printf 'error: %s must link to %s\n' "$BIN_DIR/gnu-gzip" "$GNU_GZIP_BIN" >&2 && return 1; }
            elif [[ -e "$BIN_DIR/pigz" ]]; then
                printf 'error: pigz runs as %s -p1; remove %s\n' "$PIGZ_BIN" "$BIN_DIR/pigz" >&2
                return 1
            fi
            printf 'ok: %s %s\n' "$name" "$version"
            return
            ;;
    esac
    [[ -x "$path" ]] || { printf 'missing: %s %s\n' "$name" "$version" >&2 && return 1; }
    if [[ "$name" =~ ^(std|zipir)- ]]; then
        local built
        built="$(awk -F'\t' '$1 == "source_mtime" { print $2 }' "$INSTALLS_DIR/$name/$version/receipt.tsv")"
        [[ -n "$built" && "$built" -ge "$(zig_source_mtime "$name")" ]] ||
            { printf 'stale: %s was built before its sources last changed; run tools/install.sh %s\n' "$name" "$name" >&2 && return 1; }
    fi
    case "$name" in
        libdeflate-gzip | igzip | zlib-ng)
            ! file -b "$path" | grep -q 'statically linked' ||
                { printf 'error: %s is a Zig wrapper, not the native CLI\n' "$path" >&2 && return 1; }
            ;;
    esac
    case "$name" in
        libdeflate-gzip) "$path" -V | grep -Fq "$version" ;;
        igzip) "$path" --version | grep -Fq 'unknown version' ;;
        zlib-ng) "$path" --help | grep -Fq 'Usage: minigzip' ;;
        bgzip) [[ "$("$path" --version | awk 'NR==1{print $3}')" == "$version" ]] ;;
        *) "$path" --version | grep -Fq "$version" ;;
    esac || { printf 'error: %s does not report version %s\n' "$path" "$version" >&2 && return 1; }
    case "$name" in
        libdeflate-gzip | igzip) forbidden='libdeflate|libisal|libigzip' ;;
        libdeflate-zlib) forbidden='libz\.so|libdeflate|libisal|libigzip' ;;
        flate2-miniz | flate2-zlib-rs) forbidden='libz\.so|libminiz|libdeflate' ;;
        zlib-ng | zlib-ng-zlib) forbidden='libz\.so|libdeflate|libisal' ;;
        bgzip) forbidden='libdeflate|libisal|libhts\.so' ;;
        system-zlib)
            ldd "$path" 2>/dev/null | grep -Eq 'libz\.so' ||
                { printf 'error: %s is not using the host libz\n' "$path" >&2 && return 1; }
            ;;
    esac
    assert_links "$path" "$forbidden" || return 1
    printf 'ok: %s %s\n' "$name" "$version"
}

build_zig_adapter() {
    local name="$1" work="$WORK/$1" source
    require_zig
    mkdir -p "$work/prefix"
    printf 'build: %s Zig adapter\n' "$name"
    # The configured zig owns cache selection (plan/RULES.md): no task-specific cache directories.
    zig build --build-file "$TOOLS_DIR/build.zig" -Dadapter="$name" \
        -Doptimize=ReleaseFast -Dstrip=true -Dcpu=native --prefix "$work/prefix" -j"$TOOL_JOBS"
    case "$name" in
        std-*) source="Zig ${ZIG_VERSION} standard library" ;;
        *) source="local zipir src/root.zig ${name#zipir-} adapter" ;;
    esac
    publish "$name" "$work/prefix/bin/$name" "$source" "$(zig version)" \
        "ReleaseFast;strip;single_threaded;cpu=native;x86_64-linux"
}

build_flate2() {
    local name="$1" work="$WORK/$1" backend
    require_command cargo rustc
    mkdir -p "$work/cargo-home" "$work/target"
    backend="$([[ "$name" == flate2-miniz ]] && printf 'rust_backend' || printf 'zlib-rs %s' "$ZLIB_RS_VERSION")"
    printf 'build: %s %s\n' "$name" "$backend"
    CARGO_HOME="$work/cargo-home" CARGO_TARGET_DIR="$work/target" RUSTFLAGS='-C target-cpu=native' \
        cargo build --locked --release --manifest-path "$TOOLS_DIR/rust/$name/Cargo.toml" -j "$TOOL_JOBS"
    publish "$name" "$work/target/release/$name" "crates.io flate2 $backend via tracked Cargo.lock" \
        "$(rustc --version)" "cargo-release;${backend%% *};target-cpu=native;ST"
}

# libdeflate static library plus its gzip CLI, built once per run.
build_libdeflate() {
    local work="$WORK/libdeflate"
    [[ -x "$work/prefix/bin/libdeflate-gzip" ]] && return 0
    fetch_source "$LIBDEFLATE_URL" "$work/source"
    printf 'build: libdeflate %s static library and gzip CLI\n' "$LIBDEFLATE_VERSION"
    cmake_install "$work/source" "$work/build" "$work/prefix" \
        -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=native" -DLIBDEFLATE_BUILD_SHARED_LIB=OFF \
        -DLIBDEFLATE_BUILD_STATIC_LIB=ON -DLIBDEFLATE_BUILD_GZIP=ON -DLIBDEFLATE_USE_SHARED_LIB=OFF \
        -DLIBDEFLATE_BUILD_TESTS=OFF
}

# zlib-ng configured for its minigzip CLI (native) or its native zlib API (api).
build_zlib_ng_prefix() {
    local kind="$1" work="$WORK/zlib-ng"
    fetch_source "$ZLIB_NG_URL" "$work/source"
    printf 'build: zlib-ng %s (%s)\n' "$ZLIB_NG_VERSION" "$kind"
    if [[ "$kind" == cli ]]; then
        cmake_install "$work/source" "$work/build-cli" "$work/prefix-cli" -DBUILD_SHARED_LIBS=OFF \
            -DZLIB_COMPAT=OFF -DWITH_GTEST=OFF -DWITH_FUZZERS=OFF -DWITH_BENCHMARKS=OFF \
            -DBUILD_TESTING=ON -DINSTALL_UTILS=ON -DWITH_NATIVE_INSTRUCTIONS=ON
    else
        cmake_install "$work/source" "$work/build-api" "$work/prefix-api" -DBUILD_SHARED_LIBS=OFF \
            -DZLIB_COMPAT=OFF -DWITH_GTEST=OFF -DWITH_FUZZERS=OFF -DWITH_BENCHMARKS=OFF \
            -DBUILD_TESTING=OFF -DINSTALL_UTILS=OFF -DWITH_NATIVE_INSTRUCTIONS=ON \
            -DWITH_RUNTIME_CPU_DETECTION=OFF -DWITH_NEW_STRATEGIES=OFF
    fi
}

build_target() {
    local name="$1" lib work
    case "$name" in
        std-gzip | std-zlib | zipir-gzip | zipir-zlib) build_zig_adapter "$name" ;;
        flate2-miniz | flate2-zlib-rs) build_flate2 "$name" ;;
        gnu-gzip | pigz)
            [[ "$(tool_version_text "$name")" == "$(version_for "$name")" ]] ||
                die "host $name is $(tool_version_text "$name"), pin is $(version_for "$name")"
            publish "$name" "" "host $(tool_path "$name")" "host $name $(tool_version_text "$name")" \
                "host-native;ST;$([[ "$name" == pigz ]] && printf -- '-p1;')-n"
            ;;
        system-zlib)
            require_command cc
            mkdir -p "$WORK/system-zlib"
            cc -O3 -DNDEBUG -march=native -std=c11 "$TOOLS_DIR/c/zlib_adapter.c" -lz -o "$WORK/system-zlib/$name"
            publish "$name" "$WORK/system-zlib/$name" 'host system libz' "$(cc_version)" 'Release;dynamic;zlib-api;ST;march=native'
            ;;
        libdeflate-gzip)
            build_libdeflate
            publish "$name" "$WORK/libdeflate/prefix/bin/libdeflate-gzip" "$LIBDEFLATE_URL" \
                "cmake $(cmake --version | awk 'NR==1{print $3}')" 'Release;static;gzip-cli;ST;march=native;native-cli'
            ;;
        libdeflate-zlib)
            require_command cc
            build_libdeflate
            work="$WORK/libdeflate"
            lib="$(find "$work/prefix" -type f -name 'libdeflate.a' -print -quit)"
            [[ -n "$lib" ]] || die "libdeflate static library missing after install"
            cc -O3 -DNDEBUG -march=native -std=c11 -I"$work/prefix/include" \
                "$TOOLS_DIR/c/libdeflate_zlib_adapter.c" "$lib" -o "$work/$name"
            publish "$name" "$work/$name" "$LIBDEFLATE_URL" "cc $(cc_version)" \
                'Release;static;libdeflate-zlib;full-buffer;known-output-size;ST;march=native'
            ;;
        igzip)
            require_command nasm
            work="$WORK/isal"
            fetch_source "$ISAL_URL" "$work/source"
            printf 'build: ISA-L %s igzip CLI (static, no shim, no -T)\n' "$ISAL_VERSION"
            cmake_install "$work/source" "$work/build" "$work/prefix" \
                -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=native" -DCMAKE_ASM_NASM_COMPILER="$(command -v nasm)" \
                -DBUILD_SHARED_LIBS=OFF -DISAL_BUILD_TESTS=OFF -DISAL_BUILD_PERF_TESTS=OFF \
                -DISAL_BUILD_FUZZ_TESTS=OFF -DISAL_BUILD_ISAL_SHIM=OFF -DISAL_BUILD_IGZIP_CLI=ON
            publish "$name" "$work/prefix/bin/igzip" "$ISAL_URL" \
                "cmake $(cmake --version | awk 'NR==1{print $3}'); nasm $(nasm -v | awk '{print $3}')" \
                'Release;static;igzip-cli;ST;no-shim;march=native;native-cli'
            ;;
        zlib-ng)
            build_zlib_ng_prefix cli
            publish "$name" "$WORK/zlib-ng/prefix-cli/bin/minigzip" "$ZLIB_NG_URL" \
                "cmake $(cmake --version | awk 'NR==1{print $3}')" 'Release;static;minigzip;ST;WITH_NATIVE_INSTRUCTIONS;native-cli'
            ;;
        zlib-ng-zlib)
            require_command cc
            build_zlib_ng_prefix api
            work="$WORK/zlib-ng"
            lib="$(find "$work/prefix-api" -type f \( -name 'libz-ng.a' -o -name 'libz.a' \) -print -quit)"
            [[ -n "$lib" ]] || die "zlib-ng native static library missing after install"
            cc -O3 -DNDEBUG -march=native -std=c11 -DZIPIR_ZLIB_NG_NATIVE -I"$work/prefix-api/include" \
                "$TOOLS_DIR/c/zlib_adapter.c" "$lib" -o "$work/$name"
            publish "$name" "$work/$name" "$ZLIB_NG_URL" "$(cc_version)" \
                'Release;static;zlib-ng-native-api;WITH_NATIVE_INSTRUCTIONS;NO_NEW_STRATEGIES;ST;march=native'
            ;;
        bgzip)
            require_command make cc
            work="$WORK/htslib"
            fetch_source "$HTSLIB_URL" "$work/source"
            printf 'build: htslib %s bgzip (static libhts, host libz, no libdeflate)\n' "$HTSLIB_VERSION"
            # configure links libdeflate whenever its headers are installed; that would make
            # bgzip output depend on the host, so it is always disabled.
            (
                cd "$work/source"
                ./configure --disable-bz2 --disable-lzma --disable-libcurl --without-libdeflate >/dev/null
                make -j"$TOOL_JOBS" bgzip >/dev/null
            )
            publish "$name" "$work/source/bgzip" "$HTSLIB_URL" "$(cc_version)" \
                'configure;static-libhts;host-libz;no-libdeflate;no-bz2;no-lzma;no-libcurl;ST'
            ;;
        *) usage_error "unknown target: $name" ;;
    esac
}

install_target() {
    local name="$1"
    if [[ "$REBUILD" != 1 ]] && check_target "$name" >/dev/null 2>&1; then
        link_bin "$name" "$(bin_target "$name")"
    else
        make_work tools
        build_target "$name"
    fi
    check_target "$name"
}

main() {
    local mode=install name targets
    case "${1:-}" in
        -h | --help)
            usage
            return
            ;;
        --list)
            for name in "${ALL_TARGETS[@]}"; do
                printf '%-16s %-12s %s\n' "$name" "$(version_for "$name")" \
                    "$(check_target "$name" >/dev/null 2>&1 && printf installed || printf missing)"
            done
            return
            ;;
        --rebuild) REBUILD=1 && shift ;;
        --check) mode=check && shift ;;
    esac
    [[ $# -le 1 ]] || usage_error "one target at a time; see --help"
    require_linux_x64
    [[ "$TOOL_JOBS" =~ ^[1-9][0-9]*$ ]] || die "TOOL_JOBS must be a positive integer"
    [[ "$KEEP_TOOL_WORK" =~ ^[01]$ ]] || die "KEEP_TOOL_WORK must be 0 or 1"
    targets="$(expand_target "${1:-all}")"
    for name in $targets; do
        if [[ "$mode" == check ]]; then check_target "$name"; else install_target "$name"; fi
    done
}

main "$@"
