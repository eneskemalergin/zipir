# Getting started

zipir builds with Zig 0.16.0 and nothing else. Check the compiler first:

```sh
zig version
```

It must print `0.16.0`.

## Build the command

From the repository root:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zipir --version
```

This build targets the CPU you build on. For a binary that runs on any x86-64 and still picks the fast kernels at run time, add `-Dcpu=baseline`; [Platforms and acceleration](Platforms-and-Acceleration) explains the choice.

## Compress and decompress

```sh
./zig-out/bin/zipir compress input > input.gz
./zig-out/bin/zipir decompress input.gz > input.out
cmp input input.out
./zig-out/bin/zipir test < input.gz
```

`compress` writes gzip at the `even` preset. `--fast` trades size for speed and `--dense` speed for size; `--format zlib`, `--format deflate`, and `--format bgzf` choose the other formats. `decompress` and `test` detect gzip, BGZF, and zlib by themselves.

## BGZF and tar

```sh
./zig-out/bin/zipir compress --format bgzf reads.fastq > reads.fastq.gz
./zig-out/bin/zipir bgzf index reads.fastq.gz
./zig-out/bin/zipir tar create notes > notes.tar.gz
./zig-out/bin/zipir tar list notes.tar.gz
```

`bgzf index` writes `reads.fastq.gz.gzi`, the index `bgzip -r` writes. `tar create` takes relative paths and writes gzip unless `--format` says otherwise. The [command line](Command-Line) page covers every option.

## Run the tests

```sh
zig build test --summary all
```

The [development](Development) page lists the other test modes CI and releases run.

## Use the library

The [library guide](Library-Guide) shows how to add zipir to a project's `build.zig.zon` and read and write every format.
