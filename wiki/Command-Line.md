# Command line

```text
zipir compress [--format gzip|zlib|deflate|bgzf] [--binary] [--fast|--even|--dense] [--] [FILE|-]
zipir decompress [--format auto|gzip|zlib|deflate] [--max-output-bytes N] [--] [FILE|-]
zipir test [--format auto|gzip|zlib|deflate] [--max-output-bytes N] [--] [FILE|-]
zipir bgzf index [--] FILE
zipir tar list|test [--format auto|gzip|zlib|bgzf|none] [--] [FILE|-]
zipir tar create [--format gzip|zlib|bgzf|none] [--fast|--even|--dense] [--] PATH...
zipir --version
zipir --help
```

`FILE` defaults to standard input, and `-` names it explicitly. Output goes to standard output. Input files are never changed.

## compress

Writes one gzip member at the `even` preset unless options say otherwise.

- `--format` chooses `gzip`, `zlib`, `deflate` (raw DEFLATE, no header or check), or `bgzf`.
- `--fast`, `--even`, and `--dense` choose the preset. `--level 1`, `--level 5`, and `--level 9` are accepted as their older spellings.
- `--binary` cuts BGZF blocks at full size; with any other format it is a usage error. Without it, BGZF blocks end at text lines, as `bgzip`'s do, unless the input contains a NUL byte.

The same input and preset give the same bytes on every CPU and build of one version; a later version may write different bytes that decode to the same input.

## decompress and test

`decompress` writes the decoded bytes; `test` checks the whole stream and discards them.

- `--format auto` (the default) detects gzip by its magic bytes, BGZF by its first member's `BC` subfield, and zlib by a valid two-byte header. Raw DEFLATE has no signature and needs `--format deflate`. `--format gzip` reads BGZF as ordinary gzip.
- Concatenated gzip members decode as one stream.
- `--max-output-bytes N` fails once the decoded output would pass `N` bytes.
- BGZF input without its 28-byte EOF marker is a warning for `decompress` and an error for `test`.

Output can be partial when decoding fails part way; check the exit status.

## bgzf index

`zipir bgzf index FILE` writes `FILE.gzi`, the index `bgzip -r` writes: one entry per block that holds data, except the first. It refuses to replace an existing `.gzi`.

## tar

- `tar list` prints one line per entry: mode, size, time in UTC, and name, as GNU `tar -tv --full-time` does without the owner column.
- `tar test` checks every header and the end-of-archive blocks and prints nothing.
- For both, `--format auto` also detects a plain archive (`none`). An archive without its end blocks is a warning for `list` and an error for `test`.
- `tar create` archives each `PATH` and, for directories, their contents in byte order of names. Paths must be relative and must not contain `..`. Symlinks are stored as links, never followed; hardlinked files are stored whole. Every entry gets owner 0 and time 0, so the same tree gives the same archive. Other file types are skipped with a warning.

zipir does not extract archives.

## Exit status

- `0`: success, including the warnings above.
- `1`: the input is corrupt, truncated, or has trailing data, or a file could not be read or written. Standard error names the reason, for example `zipir: CrcMismatch`.
- `2`: the arguments are wrong, or `--format auto` could not recognize the input.
