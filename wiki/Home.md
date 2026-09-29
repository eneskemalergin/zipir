# zipir

zipir is a streaming DEFLATE-family compression library and command for Zig 0.16.0: gzip, zlib, raw DEFLATE, and BGZF, compressed and decompressed, plus tar archives read and written through any of them.

Every decompressor is a `std.Io.Reader` and every compressor a `std.Io.Writer`. Each works in a fixed workspace the caller owns, allocates nothing, and starts no threads, so memory does not grow with input size and a program can run as many streams in parallel as it wants.

## Start here

- [Getting started](Getting-Started): build the command, run it, and run the tests.
- [Command line](Command-Line): every command, `--format auto`, BGZF indexes, tar, and exit statuses.
- [Library guide](Library-Guide): add zipir as a dependency, then read and write every format.
- [API reference](API): every public name, option, and error.

## Reference

- [Formats and limits](Formats-and-Limits): what each format checks, rejects, and bounds.
- [Platforms and acceleration](Platforms-and-Acceleration): supported systems, CPU kernels, and build options.
- [Benchmarking](Benchmarking): the published report, its method, and its peers.
- [Development](Development): repository layout, tests, CI, releases, and conventions.

## What comes next

- Decode each BGZF block whole with its size known, the largest remaining gap on the bioinformatics path.
- Recover the few percent that gzip, zlib, and raw DEFLATE compression gave up for the writer interface in 0.2.0.
- Extend the benchmark report: large files, more peers, and one command that reruns it.
