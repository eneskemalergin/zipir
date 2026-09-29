# Formats and limits

Decompression treats every input as untrusted: it checks each field before using it, bounds its own work and output, and reports a named error instead of reading or writing out of bounds. Compression within one version writes the same bytes for the same input and preset on every CPU and build; a later version may write different bytes that decode to the same input.

## gzip

- Concatenated members decode as one stream; empty input is `Truncated`.
- Each member's header is checked: the magic bytes, method 8 (`UnsupportedMethod`), no reserved flags (`ReservedFlag`), and the header CRC when present (`HeaderCrcMismatch`). The optional fields after the fixed ten bytes are bounded by `max_header_bytes` (`HeaderTooLong`).
- The trailer's ISIZE is checked before its CRC-32, as gzip does: a member whose length and checksum are both wrong reports `IsizeMismatch`.
- Bytes after the last member are `TrailingData`, unless `trailing_data = .leave` leaves them in the input.
- The compressor writes one member with MTIME 0 and OS 255 (unknown).

## zlib

- The two-byte header must be a valid RFC 1950 header for DEFLATE with a window of at most 32 KiB (`BadHeader`, `UnsupportedMethod`, `WindowTooLarge`). Preset dictionaries are rejected (`DictionaryUnsupported`).
- The Adler-32 trailer is checked (`BadAdler`). One stream is accepted; what follows is `TrailingData` under `.reject`.

## raw DEFLATE

- No header, trailer, or check: corruption is detected only when it breaks the DEFLATE structure. Use it inside a container that checks its own data.

## BGZF

- Every block is a gzip member whose `BC` extra subfield records its size. A block's bytes become readable only after its size fields, CRC-32, and ISIZE pass, and every block is capped at 65536 decoded bytes whatever its ISIZE claims (`BlockTooLarge`).
- A file ends with the 28-byte EOF marker. Its absence is allowed unless `require_eof_marker` is set (`MissingEofMarker`).
- `.gzi` indexes follow htslib: one entry per block that holds data, except the first. `IndexReader` rejects entries that do not increase strictly or point past the file (`BadIndex`).
- Seeking to an offset that is not a block start, or past a block's end, is `BadVirtualOffset`.

## tar

- Reads ustar, pax (`path`, `linkpath`, `size`), GNU long names and link targets, GNU base-256 numbers, and pre-POSIX archives, whose directories are regular-file entries ending in `/`.
- The archive ends at its first zero block, as GNU tar reads it; later bytes are ignored. A missing end is reported by `Summary.end_marker`.
- Names and link targets are bounded by the caller's `Names` buffers (`NameTooLong`).
- Writes ustar, with a GNU long-name header for a name or link target that does not fit ustar's fields and a base-256 size of 8 GiB or more. Names longer than `MAX_NAME` (4095 bytes) are `NameTooLong`.
- zipir does not extract archives.

## When decoded bytes become readable

gzip, zlib, and raw DEFLATE hand out decoded bytes before the check that ends their stream or member, and a failed check is reported by a later read. Bytes read before an error are therefore unverified: trust them only once the reader reports the end of the stream. zlib's `inflate` and Go's `compress/gzip` work the same way. No bounded decoder can hold back a whole member until its check, so output that precedes a damaged member cannot be withheld; the command's exit status is what reports it.

BGZF is the exception: `bgzf.Decompressor` makes a block readable only after its CRC-32 and ISIZE pass, so a damaged block's bytes are never read. Read BGZF input with it when unverified bytes must never reach the caller.

## Memory

Each workspace has a fixed size that does not grow with input, output, header fields, or block count: about 172 KB for a decompressor, 429 KB for a gzip, zlib, or raw DEFLATE compressor, and 658 KB for a BGZF compressor. The `zipir` command is designed to stay below 2 MB of peak memory on every path; the [benchmark report](https://github.com/eneskemalergin/zipir/blob/main/bench/linux-x86-avx2/README.md) shows the measured peaks.
