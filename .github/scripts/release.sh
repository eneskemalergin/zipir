#!/usr/bin/env bash
# Release checks and packages for zipir.
#
#   release.sh version                     print the version; build.zig.zon and src/root.zig must agree
#   release.sh notes [TAG]                 print the CHANGELOG.md entry for the version (TAG must be vVERSION)
#   release.sh package source OUTPUT_DIR   write and check zipir-VERSION-source.tar.gz (CI only: it fetches)
#   release.sh package SYSTEM OUTPUT_DIR   write and smoke-test zipir-VERSION-SYSTEM.tar.gz on its own runner
#
# SYSTEM is linux-x86_64, linux-aarch64, macos-x86_64, or macos-aarch64. Work directories are left in
# RUNNER_TEMP (or a mktemp directory under /tmp); nothing is deleted.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

version=$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' build.zig.zon)
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    die "build.zig.zon must declare one major.minor.patch version"
code_version=$(awk '
    /^pub const version: std.SemanticVersion = \.\{$/ { inside = 1; next }
    inside && /^\};$/ { exit }
    inside && /\.major = / { gsub(/[^0-9]/, ""); major = $0 }
    inside && /\.minor = / { gsub(/[^0-9]/, ""); minor = $0 }
    inside && /\.patch = / { gsub(/[^0-9]/, ""); patch = $0 }
    END { if (major != "" && minor != "" && patch != "") print major "." minor "." patch }
' src/root.zig)
[[ "$code_version" == "$version" ]] ||
    die "src/root.zig version (${code_version:-missing}) does not match build.zig.zon ($version)"

workdir() {
    mktemp -d "${RUNNER_TEMP:-/tmp}/zipir-release.XXXXXX"
}

# Every tracked file under build.zig.zon's .paths, sorted: what the source archive must hold, no more.
package_files() {
    local paths
    paths=$(awk '/^    \.paths = \.\{$/ { inside = 1; next } inside && /^    \},$/ { exit } inside' build.zig.zon |
        sed -n 's/^ *"\([^"]*\)",$/\1/p')
    [[ -n "$paths" ]] || die "build.zig.zon has no .paths"
    # shellcheck disable=SC2086
    git ls-files -- $paths | LC_ALL=C sort
}

package_source() {
    local output="$1" work archive name="zipir-$version-source.tar.gz"
    [[ "${CI:-}" == true ]] ||
        die "package source fetches the archive into a throwaway Zig cache; it runs in CI only"
    work=$(workdir)
    zig build source --prefix "$work/install"
    archive="$work/install/$name"
    [[ -s "$archive" ]] || die "zig build source wrote no $name"

    # The archive holds exactly the tracked package files: an untracked file under src/ or tests/ never ships.
    tar -tzf "$archive" | grep -v '/$' | LC_ALL=C sort > "$work/archived"
    package_files > "$work/tracked"
    diff -u "$work/tracked" "$work/archived" || die "the source archive does not match the tracked .paths files"

    # A fresh consumer fetches the archive (never a checkout) and runs the outside-package tests against it.
    mkdir "$work/consumer"
    cp integration/package-consumer/build.zig integration/package-consumer/main.zig "$work/consumer/"
    (
        cd "$work/consumer"
        cat > build.zig.zon <<'ZON'
.{
    .name = .zipir_package_consumer,
    .version = "0.0.0",
    .fingerprint = 0x4f58c3b67c1e05d2,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "main.zig" },
}
ZON
        zig fetch --global-cache-dir "$work/zig-cache" --save=zipir "$archive"
        zig build test --summary all --cache-dir "$work/consumer-cache" --global-cache-dir "$work/zig-cache"
    )
    mkdir -p "$output"
    cp "$archive" "$output/$name"
    printf 'tested %s\n' "$output/$name"
}

package_binary() {
    local system="$1" output="$2" work stage smoke name size binary
    case "$system" in
        linux-x86_64 | linux-aarch64 | macos-x86_64 | macos-aarch64) ;;
        *) die "unknown system: $system" ;;
    esac
    work=$(workdir)
    name="zipir-$version-$system"
    # Baseline CPU: the x86_64 binary runs on any x86-64 and still picks PCLMUL and AVX2 at run time.
    zig build -Doptimize=ReleaseFast -Dcpu=baseline --prefix "$work/install"
    stage="$work/$name"
    mkdir "$stage"
    cp "$work/install/bin/zipir" LICENSE "$stage/"
    size=$(wc -c < "$stage/zipir" | tr -d ' ')
    [[ "$size" -le 1048576 ]] || die "release binary is $size bytes; a stripped ReleaseFast build is under 1 MiB"
    tar -czf "$work/$name.tar.gz" -C "$work" "$name"

    # Smoke-test the unpacked binary, with zig off PATH.
    smoke="$work/smoke"
    mkdir "$smoke"
    tar -xzf "$work/$name.tar.gz" -C "$smoke"
    binary="$smoke/$name/zipir"
    cmp LICENSE "$smoke/$name/LICENSE"
    (
        cd "$smoke"
        export PATH=/usr/bin:/bin
        ! command -v zig > /dev/null || die "zig is still on PATH"
        [[ "$("$binary" --version)" == "zipir $version" ]] || die "--version is not 'zipir $version'"
        awk 'BEGIN { for (i = 0; i < 40000; i++) printf "@read%d\nACGTACGTNNACGT%d\n+\nIIIIIIIIIIIIII\n", i, i % 97 }' > reads.fastq
        for format in gzip zlib deflate bgzf; do
            decode=auto
            [[ "$format" == deflate ]] && decode=deflate
            [[ "$format" == bgzf ]] && decode=gzip
            for preset in --fast --even --dense; do
                "$binary" compress --format "$format" "$preset" reads.fastq > reads.z
                "$binary" decompress --format "$decode" reads.z > reads.out
                cmp reads.fastq reads.out
            done
        done
        "$binary" compress --format bgzf reads.fastq > reads.fastq.gz
        "$binary" bgzf index reads.fastq.gz
        [[ -s reads.fastq.gz.gzi ]] || die "bgzf index wrote no .gzi"
        "$binary" test reads.fastq.gz
        mkdir -p notes
        printf 'a\n' > notes/a.txt
        "$binary" tar create notes > notes.tar.gz
        [[ "$("$binary" tar list notes.tar.gz | awk '{ print $NF }' | tr '\n' ' ')" == "notes/ notes/a.txt " ]] ||
            die "tar list does not show the archived tree"
    )
    mkdir -p "$output"
    cp "$work/$name.tar.gz" "$output/"
    printf 'tested %s\n' "$output/$name.tar.gz"
}

case "${1:-}" in
    version)
        printf '%s\n' "$version"
        ;;
    notes)
        tag="${2:-v$version}"
        [[ "$tag" == "v$version" ]] || die "tag $tag does not match version v$version"
        awk -v version="$version" '
            /^## / {
                if (found) exit
                found = ($2 == "[" version "]")
                next
            }
            found {
                print
                if ($0 ~ /[^[:space:]]/) nonempty = 1
            }
            END { if (!found || !nonempty) exit 1 }
        ' CHANGELOG.md || die "CHANGELOG.md needs a nonempty [$version] entry"
        ;;
    package)
        [[ $# -eq 3 ]] || die "usage: release.sh package source|SYSTEM OUTPUT_DIR"
        if [[ "$2" == source ]]; then package_source "$3"; else package_binary "$2" "$3"; fi
        ;;
    *)
        printf 'usage: release.sh version | notes [TAG] | package source|SYSTEM OUTPUT_DIR\n' >&2
        exit 2
        ;;
esac
