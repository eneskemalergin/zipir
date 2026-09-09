# Gzip contract fixtures

These are deterministic synthetic inputs, not downloaded user data. Expected plaintext is frozen separately so the decoder under test is not its own oracle. Large decoded fixtures exercise staging and history boundaries; only tests retain their complete output.

- `short6` covers short overlapping matches; `long-header` adds a 65,535-byte extra field, 70,000-byte name, 66,000-byte comment and FHCRC to the same plaintext.
- `final-stored-concat` crosses staging in a final stored block before the next member uses matches.
- `copy-boundaries` explicitly encodes match lengths 3-258 and distances through 32,768 in two members. Its larger expected plaintext checks all copied bytes across history and output boundaries.
- `long-codes` contains valid 15-bit literal/length and distance codes and a long end-of-block code.
- `repeat-zero` exercises a legal zero code-length repeat. The `invalid-*` files reject impossible history and an incorrect FHCRC.
- `empty-single` is a legal empty member with a single one-bit end-of-block code and empty distance alphabet. The incomplete and oversubscribed tree fixtures are rejected by independent Python zlib.

Local provenance and generators are retained in `tmp/next/`: `make_copy_fixture.py`, `make_final_stored_fixture.py`, `make_long_fixture.py`, `make_stream_fixture.py`, and `p01_vectors.py`. Those local scripts are not required to run the self-contained test suite. GNU gzip and Python zlib validate the applicable valid vectors; `tmp/next/P01.md` records the integration checks.
