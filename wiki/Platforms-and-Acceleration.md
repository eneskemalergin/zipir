# Platforms and acceleration

## Supported systems

zipir supports Linux and macOS on x86-64 and ARM64. CI builds and tests all four on their own runners, and the release publishes a command binary for each.

Windows is not supported. I would like to support it properly, but keeping native Windows builds reliable takes more time than I can justify, and I would rather say so than publish something I cannot support well. WSL with the Linux build may work; I have not tested it.

## CPU kernels

The DEFLATE engine is portable Zig on every system. Two checksum kernels have faster paths:

| Kernel | x86-64 | ARM64 |
| --- | --- | --- |
| CRC-32 (gzip, BGZF) | PCLMUL fold, chosen at run time | ARMv8 CRC instruction when the build target has it |
| Adler-32 (zlib) | AVX2, chosen at run time | portable |

On x86-64, zipir asks the CPU once which features it has and picks each kernel from the answer, so one binary is fast on a new CPU and still correct on an old one. On ARM64 the choice is made when the program is built: a build for a CPU with the CRC extension, such as any Apple silicon Mac, uses the instruction; a build for the generic ARM64 baseline uses the portable path. Every accelerated kernel keeps a portable twin, and tests check each against an independent reference.

Acceleration is x86-64 first: every speed number I publish is from Linux x86-64 with AVX2.

## Build options

- The default build targets the CPU you build on.
- `-Dcpu=baseline` targets the oldest CPU of the architecture. On x86-64 the binary still picks PCLMUL and AVX2 at run time; the release binaries are built this way.
- `-Dkernel-backend=portable` forces every kernel onto its portable path, for testing or for comparing speed. It replaces 0.1.2's `-Dadler-backend=scalar`. A dependent passes it as `.@"kernel-backend" = .portable`.
- `-Doptimize=ReleaseFast` is the release mode; it also strips the command.

## Threads and memory

zipir starts no threads and allocates nothing while it compresses or decompresses. Each stream lives in one fixed workspace, so a program can run as many streams in parallel as it has cores, each on its own workspace.
