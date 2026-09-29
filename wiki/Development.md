# Development

## Layout

- `src/engine/`: the DEFLATE decoder and encoder shared by every format.
- `src/stream/`: the `std.Io.Reader` and `std.Io.Writer` every decompressor and compressor is.
- `src/format/`: gzip, zlib, raw DEFLATE, and BGZF.
- `src/archive/`: tar.
- `src/kernel/`: CRC-32, Adler-32, and match copies, with their CPU-specific paths.
- `src/cli/`: the `zipir` command.
- `tests/`: the public contract tests and their fixtures.
- `integration/package-consumer/`: an outside package that depends on zipir by path and tests the public module.
- `tools/` and `bench/`: the peer comparison and the published benchmark report.

## Tests

```sh
zig fmt --check src tests build.zig tools/build.zig tools/zig integration
zig build test --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build test -Dkernel-backend=portable --summary all
zig build test -Dcpu=baseline --summary all
cd integration/package-consumer && zig build test --summary all
```

Every test is named `[type] - [target]: behavior`, for example `[failure] - [gzip decompressor]: ...`, with the type one of `unit`, `edge`, `failure`, `property`, `fuzz`, `regression`, `integration`, or `cli`.

## CI

Each push to `main` or `dev` and each pull request runs one graph. A quick job checks formatting, scripts, and the version, and decides from the changed files what else must run; documentation-only changes skip the tests. Then, in parallel: the tests on Linux and macOS for x86-64 and ARM64, the source package (built, fetched into a fresh project, and tested there), and, when workflows change, `actionlint` and `zizmor`.

## Releases

`zig build source` writes `zipir-VERSION-source.tar.gz`: every path in `build.zig.zon`'s `.paths`, archived by zipir's own tar writer so the same tree gives the same bytes.

A release is a tag `vX.Y.Z` on `main`'s head. The tag must match the version in `build.zig.zon` and `src/root.zig` and have a `CHANGELOG.md` entry. The release workflow runs the whole CI graph on the tagged commit without caches, packages and smoke-tests a binary on each system, and publishes the source package, the four binaries, `SHA256SUMS`, and build attestations with the changelog entry as notes.

## Conventions

- Zig source carries one comment: the `//!` module statement at the top of each file, which holds every contract the code cannot show. There are no `//` or `///` comments.
- Commit messages are one line, `type: subject`, 72 characters or less: `feat`, `fix`, `perf`, `refactor`, `build`, `test`, `docs`, `chore`, `ci`, or `revert`.
- Windows is not a supported platform; please do not send changes for it.
