# zipir benchmark: linux-x86-avx2

zipir `ff8e9e87ddb6` (clean tree), measured on 2026-09-26. One host: AMD Ryzen 9 3950X, Linux 7.2.7-200.fc44.x86_64 x86_64.

This report shows where zipir stands against the fastest single-threaded tools on the same machine, on every format zipir writes and reads. Compression is a trade-off between speed and output size, so compression results always show both; decompression output is identical across tools, so speed and memory are the whole story there.

## Summary

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="figures/summary-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="figures/summary-light.svg">
    <img src="figures/summary-light.svg" alt="zipir against the fastest peer on every path" width="100%">
  </picture>
</p>

Each row compares zipir with every peer on the same path and names the fastest one; its marker sits left of 1.0 when the peer is faster. For compression, the fastest peer is often fast because it writes larger output, so a hollow marker shows the fastest peer whose output is no larger than zipir's (within 1%). "Level 1" compares each tool's fast level, "5" balanced, and "9" dense, on each tool's own scale ([Levels](#levels)).

| Path | Level | Fastest peer | Peer time / zipir (range) | Its output | Fastest peer no larger than zipir | zipir MB/s |
| --- | ---: | --- | ---: | ---: | --- | ---: |
| gzip decompress |  | ISA-L igzip | 1.01 (0.81 to 1.25) |  |  | 544 to 1082 |
| zlib decompress |  | zlib-ng | 1.24 (1.17 to 1.27) |  |  | 569 to 1171 |
| raw DEFLATE decompress |  | zlib-ng | 1.24 (1.18 to 1.28) |  |  | 567 to 1210 |
| BGZF decompress |  | bgzip + libdeflate | 0.94 (0.85 to 1.11) |  |  | 586 to 1030 |
| gzip compress | 1 | ISA-L igzip 0 | 0.49 (0.38 to 0.59) | +18% size | Zig std 1: 2.66 | 151 to 282 |
| gzip compress | 5 | ISA-L igzip 1 | 0.23 (0.18 to 0.31) | +13% size | zlib-ng 5: 0.90 | 55 to 124 |
| gzip compress | 9 | ISA-L igzip 2 | 0.18 (0.09 to 0.31) | +14% size | zlib-ng 9: 2.69 | 27 to 101 |
| zlib compress | 1 | zlib-ng 1 | 0.79 (0.74 to 0.88) | +30% size | none | 154 to 287 |
| zlib compress | 5 | zlib-ng 5 | 0.91 (0.80 to 1.05) | -0.6% size | zlib-ng 5: 0.91 | 57 to 125 |
| zlib compress | 9 | zlib-ng 9 | 2.71 (1.61 to 5.95) | +0.6% size | zlib-ng 9: 2.71 | 27 to 104 |
| raw DEFLATE compress | 1 | zlib-ng 1 | 0.80 (0.75 to 0.88) | +30% size | none | 153 to 295 |
| raw DEFLATE compress | 5 | zlib-ng 5 | 0.91 (0.79 to 1.05) | -0.6% size | zlib-ng 5: 0.91 | 55 to 127 |
| raw DEFLATE compress | 9 | zlib-ng 9 | 2.71 (1.59 to 5.97) | +0.6% size | zlib-ng 9: 2.71 | 27 to 103 |
| BGZF compress | 1 | bgzip + zlib-ng 1 | 0.81 (0.74 to 0.88) | +29% size | bgzip + libdeflate 1: 0.97 | 191 to 287 |
| BGZF compress | 5 | bgzip + zlib-ng 5 | 0.93 (0.85 to 0.99) | same size | bgzip + zlib-ng 5: 0.93 | 81 to 120 |
| BGZF compress | 9 | bgzip + zlib-ng 9 | 2.33 (1.62 to 5.26) | +0.7% size | bgzip + zlib-ng 9: 2.33 | 65 to 108 |

### Reading the summary

- Decompression: zipir is the fastest tool on zlib and raw DEFLATE.
- Decompression: on gzip, zipir and ISA-L igzip are level on average; per file the peer ranges from 0.80x to 1.24x zipir's speed.
- Decompression: on BGZF, bgzip + libdeflate is 1.07x faster than zipir on average (0.90x to 1.18x across files).
- Compression level 1 (fast): no peer with output no larger than zipir's is faster on gzip; no peer reaches zipir's output size on zlib and raw DEFLATE; bgzip + libdeflate 1 is 1.03x faster at no larger output on BGZF; the fastest peer at any size is ISA-L igzip 0, 2.0x faster with 18% larger output.
- Compression level 5 (balanced): zlib-ng 5 is 1.11x faster at no larger output on gzip; zlib-ng 5 is 1.10x faster at no larger output on zlib and raw DEFLATE; bgzip + zlib-ng 5 is 1.07x faster at no larger output on BGZF; the fastest peer at any size is ISA-L igzip 1, 4.4x faster with 13% larger output.
- Compression level 9 (dense): no peer with output no larger than zipir's is faster on gzip, zlib, raw DEFLATE and BGZF; the fastest peer at any size is ISA-L igzip 2, 5.7x faster with 14% larger output.
- Memory: zipir peaks at 0.56 to 0.65 MiB on every path; the C tools peak at 1.6 to 5.0 MiB (whole process, see [Memory](#memory)).

## Compression: speed against ratio

A single level says little about a compressor: a faster tool can simply be writing more bytes. These figures place every tool's fast, balanced, and dense levels on speed and compression ratio together. zlib and raw DEFLATE use the same engine as gzip in every tool here, so their curves follow gzip's; their figures and tables are in the folded sections below. zlib and raw DEFLATE have no ISA-L or Zig std compressor in this run.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="figures/tradeoff-gzip-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="figures/tradeoff-gzip-light.svg">
    <img src="figures/tradeoff-gzip-light.svg" alt="gzip compression speed against compression ratio" width="100%">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="figures/tradeoff-bgzf-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="figures/tradeoff-bgzf-light.svg">
    <img src="figures/tradeoff-bgzf-light.svg" alt="BGZF compression speed against compression ratio" width="100%">
  </picture>
</p>

Each cell: MB/s · compression ratio. Peer cells add their time relative to zipir at the same level (below 1× is faster) and their output size relative to zipir's (+ is larger).

### gzip compression

| Tool | Level | FASTQ, 57.2 MB | FASTQ, 20.2 MB | PRIDE XML, 48.0 MB | mzIdentML, 1.2 MB | Canterbury tar, 2.8 MB |
| --- | --- | --- | --- | --- | --- | --- |
| **zipir** | 1 | 150.6 MB/s · 2.185 | 281.9 MB/s · 4.552 | 239.2 MB/s · 4.040 | 199.8 MB/s · 4.236 | 190.1 MB/s · 3.219 |
| **zipir** | 5 | 54.9 MB/s · 2.553 | 123.5 MB/s · 5.832 | 112.2 MB/s · 4.486 | 99.2 MB/s · 4.634 | 77.6 MB/s · 3.827 |
| **zipir** | 9 | 26.7 MB/s · 2.640 | 83.0 MB/s · 6.171 | 100.7 MB/s · 4.527 | 92.5 MB/s · 4.694 | 60.1 MB/s · 3.866 |
| zlib-ng | 1 | 192.7 MB/s · 1.677 · 0.78× · +30% | 363.3 MB/s · 3.648 · 0.78× · +25% | 317.7 MB/s · 3.332 · 0.75× · +21% | 229.2 MB/s · 3.008 · 0.87× · +41% | 241.5 MB/s · 2.449 · 0.79× · +31% |
| zlib-ng | 5 | 52.4 MB/s · 2.589 · 1.05× · -1.4% | 128.3 MB/s · 5.999 · 0.96× · -3% | 141.9 MB/s · 4.482 · 0.79× · ±0% | 114.9 MB/s · 4.662 · 0.86× · -0.6% | 89.2 MB/s · 3.759 · 0.87× · +2% |
| zlib-ng | 9 | 6.2 MB/s · 2.648 · 4.28× · ±0% | 43.6 MB/s · 6.256 · 1.90× · -1.4% | 63.2 MB/s · 4.511 · 1.59× · ±0% | 49.7 MB/s · 4.521 · 1.86× · +4% | 10.3 MB/s · 3.847 · 5.85× · ±0% |
| ISA-L igzip | 0 | 327.4 MB/s · 2.095 · 0.46× · +4% | 564.3 MB/s · 4.106 · 0.50× · +11% | 632.2 MB/s · 3.231 · 0.38× · +25% | 340.1 MB/s · 2.965 · 0.59× · +43% | 344.7 MB/s · 2.957 · 0.55× · +9% |
| ISA-L igzip | 1 | 300.3 MB/s · 2.371 · 0.18× · +8% | 533.3 MB/s · 4.877 · 0.23× · +20% | 579.1 MB/s · 4.054 · 0.19× · +11% | 322.8 MB/s · 4.293 · 0.31× · +8% | 312.2 MB/s · 3.225 · 0.25× · +19% |
| ISA-L igzip | 2 | 286.6 MB/s · 2.399 · 0.09× · +10% | 511.9 MB/s · 4.917 · 0.16× · +25% | 556.0 MB/s · 4.184 · 0.18× · +8% | 297.4 MB/s · 4.362 · 0.31× · +8% | 310.4 MB/s · 3.282 · 0.19× · +18% |
| Zig std | 1 | 60.1 MB/s · 2.367 · 2.50× · -8% | 89.4 MB/s · 4.486 · 3.15× · +1.5% | 83.9 MB/s · 3.922 · 2.85× · +3% | 83.4 MB/s · 3.970 · 2.40× · +7% | 76.5 MB/s · 3.302 · 2.48× · -3% |
| Zig std | 5 | 25.8 MB/s · 2.516 · 2.13× · +1.5% | 63.5 MB/s · 5.540 · 1.95× · +5% | 70.8 MB/s · 4.366 · 1.59× · +3% | 47.9 MB/s · 4.296 · 2.07× · +8% | 42.0 MB/s · 3.688 · 1.85× · +4% |
| Zig std | 9 | 4.3 MB/s · 2.648 · 6.26× · ±0% | 18.6 MB/s · 6.213 · 4.46× · -0.7% | 16.1 MB/s · 4.499 · 6.25× · +0.6% | 37.4 MB/s · 4.477 · 2.47× · +5% | 6.7 MB/s · 3.802 · 8.95× · +2% |

<details><summary><b>zlib compression</b> (same engines as gzip)</summary>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="figures/tradeoff-zlib-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="figures/tradeoff-zlib-light.svg">
    <img src="figures/tradeoff-zlib-light.svg" alt="zlib compression speed against compression ratio" width="100%">
  </picture>
</p>

| Tool | Level | FASTQ, 57.2 MB | FASTQ, 20.2 MB | PRIDE XML, 48.0 MB | mzIdentML, 1.2 MB | Canterbury tar, 2.8 MB |
| --- | --- | --- | --- | --- | --- | --- |
| **zipir** | 1 | 154.4 MB/s · 2.185 | 287.4 MB/s · 4.553 | 247.2 MB/s · 4.040 | 199.8 MB/s · 4.236 | 192.4 MB/s · 3.219 |
| **zipir** | 5 | 56.5 MB/s · 2.553 | 125.2 MB/s · 5.832 | 116.0 MB/s · 4.486 | 99.0 MB/s · 4.634 | 79.3 MB/s · 3.828 |
| **zipir** | 9 | 27.1 MB/s · 2.640 | 83.6 MB/s · 6.171 | 103.9 MB/s · 4.527 | 92.2 MB/s · 4.694 | 61.4 MB/s · 3.866 |
| zlib-ng | 1 | 198.2 MB/s · 1.677 · 0.78× · +30% | 371.7 MB/s · 3.648 · 0.77× · +25% | 332.2 MB/s · 3.332 · 0.74× · +21% | 227.0 MB/s · 3.008 · 0.88× · +41% | 247.2 MB/s · 2.449 · 0.78× · +31% |
| zlib-ng | 5 | 53.7 MB/s · 2.589 · 1.05× · -1.4% | 131.1 MB/s · 5.999 · 0.96× · -3% | 145.4 MB/s · 4.482 · 0.80× · ±0% | 115.2 MB/s · 4.662 · 0.86× · -0.6% | 89.8 MB/s · 3.760 · 0.88× · +2% |
| zlib-ng | 9 | 6.3 MB/s · 2.648 · 4.29× · ±0% | 43.8 MB/s · 6.256 · 1.91× · -1.4% | 64.6 MB/s · 4.511 · 1.61× · ±0% | 49.5 MB/s · 4.521 · 1.86× · +4% | 10.3 MB/s · 3.847 · 5.95× · ±0% |

</details>

<details><summary><b>raw DEFLATE compression</b> (same engines as gzip)</summary>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="figures/tradeoff-deflate-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="figures/tradeoff-deflate-light.svg">
    <img src="figures/tradeoff-deflate-light.svg" alt="raw DEFLATE compression speed against compression ratio" width="100%">
  </picture>
</p>

| Tool | Level | FASTQ, 57.2 MB | FASTQ, 20.2 MB | PRIDE XML, 48.0 MB | mzIdentML, 1.2 MB | Canterbury tar, 2.8 MB |
| --- | --- | --- | --- | --- | --- | --- |
| **zipir** | 1 | 153.0 MB/s · 2.185 | 295.5 MB/s · 4.553 | 250.3 MB/s · 4.040 | 197.8 MB/s · 4.236 | 198.1 MB/s · 3.219 |
| **zipir** | 5 | 55.2 MB/s · 2.553 | 126.8 MB/s · 5.832 | 115.6 MB/s · 4.486 | 97.6 MB/s · 4.634 | 80.0 MB/s · 3.828 |
| **zipir** | 9 | 26.8 MB/s · 2.640 | 84.7 MB/s · 6.171 | 103.0 MB/s · 4.527 | 91.6 MB/s · 4.694 | 61.7 MB/s · 3.866 |
| zlib-ng | 1 | 195.3 MB/s · 1.677 · 0.78× · +30% | 376.4 MB/s · 3.648 · 0.78× · +25% | 334.2 MB/s · 3.332 · 0.75× · +21% | 224.0 MB/s · 3.008 · 0.88× · +41% | 250.6 MB/s · 2.449 · 0.79× · +31% |
| zlib-ng | 5 | 52.6 MB/s · 2.589 · 1.05× · -1.4% | 132.3 MB/s · 5.999 · 0.96× · -3% | 145.8 MB/s · 4.482 · 0.79× · ±0% | 111.3 MB/s · 4.662 · 0.88× · -0.6% | 91.1 MB/s · 3.760 · 0.88× · +2% |
| zlib-ng | 9 | 6.2 MB/s · 2.648 · 4.33× · ±0% | 44.4 MB/s · 6.256 · 1.91× · -1.4% | 64.6 MB/s · 4.511 · 1.59× · ±0% | 49.0 MB/s · 4.521 · 1.87× · +4% | 10.3 MB/s · 3.847 · 5.97× · ±0% |

</details>

### BGZF compression

| Tool | Level | BAM, 76.2 MB | VCF, 11.5 MB | PRIDE XML, 48.0 MB | mzIdentML, 1.2 MB | Canterbury tar, 2.8 MB |
| --- | --- | --- | --- | --- | --- | --- |
| **zipir** | 1 | 287.4 MB/s · 4.468 | 222.2 MB/s · 3.491 | 255.2 MB/s · 3.885 | 202.6 MB/s · 4.154 | 190.8 MB/s · 3.179 |
| **zipir** | 5 | 114.9 MB/s · 5.700 | 98.2 MB/s · 4.575 | 120.0 MB/s · 4.200 | 104.4 MB/s · 4.463 | 81.2 MB/s · 3.718 |
| **zipir** | 9 | 80.0 MB/s · 5.820 | 65.2 MB/s · 4.779 | 108.2 MB/s · 4.235 | 97.9 MB/s · 4.511 | 64.6 MB/s · 3.746 |
| bgzip + libdeflate | 1 | 295.3 MB/s · 5.283 · 0.97× · -15% | 243.4 MB/s · 3.986 · 0.91× · -12% | 256.6 MB/s · 4.020 · 0.99× · -3% | 184.6 MB/s · 4.254 · 1.10× · -2% | 212.2 MB/s · 3.472 · 0.90× · -8% |
| bgzip + libdeflate | 5 | 102.0 MB/s · 5.850 · 1.13× · -3% | 91.1 MB/s · 4.849 · 1.08× · -6% | 135.2 MB/s · 4.238 · 0.89× · -0.9% | 114.8 MB/s · 4.666 · 0.91× · -4% | 80.4 MB/s · 3.786 · 1.01× · -2% |
| bgzip + libdeflate | 9 | 3.0 MB/s · 6.296 · 26.28× · -8% | 3.0 MB/s · 5.390 · 21.91× · -11% | 4.8 MB/s · 4.359 · 22.56× · -3% | 2.9 MB/s · 4.928 · 34.14× · -8% | 5.3 MB/s · 4.032 · 12.21× · -7% |
| bgzip + zlib-ng | 1 | 369.5 MB/s · 3.712 · 0.78× · +20% | 268.9 MB/s · 2.688 · 0.83× · +30% | 345.7 MB/s · 3.191 · 0.74× · +22% | 230.3 MB/s · 2.921 · 0.88× · +42% | 235.2 MB/s · 2.415 · 0.81× · +32% |
| bgzip + zlib-ng | 5 | 115.6 MB/s · 5.758 · 0.99× · -1.0% | 99.7 MB/s · 4.667 · 0.99× · -2% | 141.5 MB/s · 4.197 · 0.85× · ±0% | 112.3 MB/s · 4.501 · 0.93× · -0.8% | 90.0 MB/s · 3.660 · 0.90× · +2% |
| bgzip + zlib-ng | 9 | 32.2 MB/s · 5.944 · 2.48× · -2% | 37.5 MB/s · 4.777 · 1.74× · ±0% | 66.6 MB/s · 4.202 · 1.62× · +0.8% | 52.2 MB/s · 4.300 · 1.88× · +5% | 12.3 MB/s · 3.745 · 5.26× · ±0% |

## Decompression

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="figures/decode-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="figures/decode-light.svg">
    <img src="figures/decode-light.svg" alt="Decompression throughput on the medium files" width="100%">
  </picture>
</p>

Each cell: MB/s of decoded output; peer cells add their time relative to zipir (below 1× is faster).

### gzip decompression

| Tool | FASTQ, 57.2 MB | FASTQ, 20.2 MB | PRIDE XML, 48.0 MB | mzIdentML, 1.2 MB | Silesia tar, 211.9 MB | Canterbury tar, 2.8 MB |
| --- | --- | --- | --- | --- | --- | --- |
| **zipir** | 544 MB/s | 1082 MB/s | 937 MB/s | 569 MB/s | 697 MB/s | 732 MB/s |
| zlib-ng | 476 MB/s · 1.14× | 945 MB/s · 1.15× | 829 MB/s · 1.13× | 451 MB/s · 1.26× | 633 MB/s · 1.10× | 605 MB/s · 1.21× |
| ISA-L igzip | 673 MB/s · 0.81× | 1159 MB/s · 0.93× | 947 MB/s · 0.99× | 455 MB/s · 1.25× | 745 MB/s · 0.94× | 605 MB/s · 1.21× |
| Zig std | 213 MB/s · 2.55× | 473 MB/s · 2.29× | 381 MB/s · 2.46× | 275 MB/s · 2.07× | 267 MB/s · 2.61× | 293 MB/s · 2.50× |

### zlib decompression

| Tool | FASTQ, 57.2 MB | FASTQ, 20.2 MB | PRIDE XML, 48.0 MB | mzIdentML, 1.2 MB | Silesia tar, 211.9 MB | Canterbury tar, 2.8 MB |
| --- | --- | --- | --- | --- | --- | --- |
| **zipir** | 569 MB/s | 1171 MB/s | 1028 MB/s | 623 MB/s | 726 MB/s | 738 MB/s |
| zlib-ng | 453 MB/s · 1.26× | 934 MB/s · 1.25× | 839 MB/s · 1.22× | 489 MB/s · 1.27× | 618 MB/s · 1.17× | 587 MB/s · 1.26× |
| Zig std | 203 MB/s · 2.79× | 425 MB/s · 2.75× | 351 MB/s · 2.92× | 268 MB/s · 2.33× | 250 MB/s · 2.91× | 265 MB/s · 2.78× |

### raw DEFLATE decompression

| Tool | FASTQ, 57.2 MB | FASTQ, 20.2 MB | PRIDE XML, 48.0 MB | mzIdentML, 1.2 MB | Silesia tar, 211.9 MB | Canterbury tar, 2.8 MB |
| --- | --- | --- | --- | --- | --- | --- |
| **zipir** | 567 MB/s | 1210 MB/s | 1040 MB/s | 607 MB/s | 746 MB/s | 754 MB/s |
| zlib-ng | 452 MB/s · 1.25× | 969 MB/s · 1.25× | 857 MB/s · 1.21× | 474 MB/s · 1.28× | 635 MB/s · 1.18× | 607 MB/s · 1.24× |

### BGZF decompression

| Tool | BAM, 76.2 MB | VCF, 11.5 MB | PRIDE XML, 48.0 MB | mzIdentML, 1.2 MB | Silesia tar, 211.9 MB | Canterbury tar, 2.8 MB |
| --- | --- | --- | --- | --- | --- | --- |
| **zipir** | 1030 MB/s | 873 MB/s | 893 MB/s | 586 MB/s | 647 MB/s | 662 MB/s |
| bgzip + libdeflate | 1201 MB/s · 0.86× | 990 MB/s · 0.88× | 975 MB/s · 0.92× | 528 MB/s · 1.11× | 765 MB/s · 0.85× | 640 MB/s · 1.03× |
| bgzip + zlib-ng | 945 MB/s · 1.09× | 808 MB/s · 1.08× | 819 MB/s · 1.09× | 472 MB/s · 1.24× | 612 MB/s · 1.06× | 578 MB/s · 1.15× |

## Memory

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="figures/memory-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="figures/memory-light.svg">
    <img src="figures/memory-light.svg" alt="Peak memory of the whole process by tool" width="100%">
  </picture>
</p>

| Tool | Decompression peak RSS (MiB) | Compression peak RSS (MiB) |
| --- | ---: | ---: |
| **zipir** | 0.61 to 0.62 | 0.56 to 0.65 |
| zlib-ng | 1.6 to 2.1 | 1.6 to 2.1 |
| ISA-L igzip | 2.9 to 3.7 | 2.9 to 3.6 |
| Zig std | 0.61 to 0.62 | 0.65 to 0.65 |
| bgzip + libdeflate | 2.4 to 2.7 | 2.7 to 5.0 |
| bgzip + zlib-ng | 2.4 to 2.5 | 2.9 to 3.0 |

## zipir efficiency

CPU cycles and instructions per plaintext byte for zipir on the medium files, from the same runs (user-space counters, median of 25 rounds). IPC is instructions per cycle.

| Path | Input | Cycles / byte | Instructions / byte | IPC | MB/s |
| --- | --- | ---: | ---: | ---: | ---: |
| gzip compress 1 | PRIDE XML, 48.0 MB | 14.74 | 23.97 | 1.63 | 239.2 |
| gzip compress 5 | PRIDE XML, 48.0 MB | 32.12 | 61.24 | 1.91 | 112.2 |
| gzip compress 9 | PRIDE XML, 48.0 MB | 35.80 | 68.21 | 1.91 | 100.7 |
| gzip compress 1 | FASTQ, 57.2 MB | 23.75 | 45.53 | 1.92 | 150.6 |
| gzip compress 5 | FASTQ, 57.2 MB | 66.34 | 143.90 | 2.17 | 54.9 |
| gzip compress 9 | FASTQ, 57.2 MB | 136.71 | 292.43 | 2.14 | 26.7 |
| gzip decompress | Silesia tar, 211.9 MB | 5.14 | 13.90 | 2.70 | 697.2 |
| gzip decompress | PRIDE XML, 48.0 MB | 3.79 | 10.37 | 2.74 | 937.3 |
| gzip decompress | FASTQ, 57.2 MB | 6.59 | 16.77 | 2.54 | 543.8 |
| zlib compress 1 | PRIDE XML, 48.0 MB | 14.28 | 23.98 | 1.68 | 247.2 |
| zlib compress 5 | PRIDE XML, 48.0 MB | 31.06 | 60.89 | 1.96 | 116.0 |
| zlib compress 9 | PRIDE XML, 48.0 MB | 34.68 | 67.86 | 1.96 | 103.9 |
| zlib compress 1 | FASTQ, 57.2 MB | 23.26 | 45.90 | 1.97 | 154.4 |
| zlib compress 5 | FASTQ, 57.2 MB | 64.51 | 143.51 | 2.22 | 56.5 |
| zlib compress 9 | FASTQ, 57.2 MB | 135.01 | 292.04 | 2.16 | 27.1 |
| zlib decompress | Silesia tar, 211.9 MB | 4.93 | 14.09 | 2.86 | 726.4 |
| zlib decompress | PRIDE XML, 48.0 MB | 3.44 | 10.31 | 3.00 | 1027.8 |
| zlib decompress | FASTQ, 57.2 MB | 6.27 | 16.36 | 2.61 | 568.7 |
| raw DEFLATE compress 1 | PRIDE XML, 48.0 MB | 14.10 | 23.69 | 1.68 | 250.3 |
| raw DEFLATE compress 5 | PRIDE XML, 48.0 MB | 31.13 | 60.60 | 1.95 | 115.6 |
| raw DEFLATE compress 9 | PRIDE XML, 48.0 MB | 35.01 | 67.57 | 1.93 | 103.0 |
| raw DEFLATE compress 1 | FASTQ, 57.2 MB | 23.11 | 45.61 | 1.97 | 153.0 |
| raw DEFLATE compress 5 | FASTQ, 57.2 MB | 65.62 | 143.22 | 2.18 | 55.2 |
| raw DEFLATE compress 9 | FASTQ, 57.2 MB | 135.44 | 291.75 | 2.15 | 26.8 |
| raw DEFLATE decompress | Silesia tar, 211.9 MB | 4.81 | 13.80 | 2.87 | 746.3 |
| raw DEFLATE decompress | PRIDE XML, 48.0 MB | 3.40 | 10.02 | 2.95 | 1040.0 |
| raw DEFLATE decompress | FASTQ, 57.2 MB | 6.27 | 16.07 | 2.56 | 566.8 |
| BGZF compress 1 | PRIDE XML, 48.0 MB | 13.69 | 24.38 | 1.78 | 255.2 |
| BGZF compress 5 | PRIDE XML, 48.0 MB | 29.52 | 60.98 | 2.07 | 120.0 |
| BGZF compress 9 | PRIDE XML, 48.0 MB | 32.96 | 68.61 | 2.08 | 108.2 |
| BGZF compress 1 | BAM, 76.2 MB | 12.22 | 23.36 | 1.91 | 287.4 |
| BGZF compress 5 | BAM, 76.2 MB | 31.42 | 67.87 | 2.16 | 114.9 |
| BGZF compress 9 | BAM, 76.2 MB | 45.23 | 98.67 | 2.18 | 80.0 |
| BGZF decompress | Silesia tar, 211.9 MB | 5.53 | 15.75 | 2.85 | 647.3 |
| BGZF decompress | PRIDE XML, 48.0 MB | 3.98 | 11.87 | 2.99 | 892.9 |
| BGZF decompress | BAM, 76.2 MB | 3.47 | 8.40 | 2.43 | 1030.5 |

## Terms

- **Peer time / zipir time**: median wall time of the peer divided by zipir's median in the same batch and level lane. Below 1.00 the peer is faster. Summary values are geometric means over files.
- **Output size**: the peer's compressed bytes divided by zipir's at the same lane. "+25% size" means the peer wrote 25% more bytes.
- **Compression ratio**: plaintext bytes divided by compressed bytes; higher is smaller output.
- **MB/s**: plaintext (decoded) MB, 10^6 bytes, per second of median wall time, for both directions.
- **Peak RSS**: the maximum resident set size of the whole process, as Zebrac reports it. It includes the program's runtime, libc for the C tools, I/O buffers, and codec state.
- **Streaming**: the tool reads and writes through fixed buffers, so memory does not grow with the input. Every tool in this report streams; full-buffer decoders (such as libdeflate's one-shot API) are not in this run.

### Levels

| Tool | fast | balanced | dense | Scale |
| --- | --- | --- | --- | --- |
| zipir | 1 | 5 | 9 | 1, 5, 9 (the only levels) |
| zlib-ng | 1 | 5 | 9 | 0 to 9 |
| ISA-L igzip | 0 | 1 | 2 | 0 to 3; level 3 was not on its own speed-size frontier |
| Zig std | 1 | 5 | 9 | 1 to 9 |
| bgzip + libdeflate | 1 | 5 | 9 | bgzip -l 0 to 9; htslib maps 1, 5, 9 to libdeflate 1, 6, 12 |
| bgzip + zlib-ng | 1 | 5 | 9 | bgzip -l 0 to 9 |

Peer levels were chosen from peer-only measurements, never from a zipir result.

## Inputs

| Category | Class | Format | File | Plaintext | Stored | Operations |
| --- | --- | --- | --- | --- | --- | --- |
| Sequencing | small | gzip | `SRR389222_sub1.fastq.gz` | 20.2 MB | 3.3 MB | compress, decompress |
| Sequencing | small | zlib | `SRR389222_sub1.fastq.zlib` | 20.2 MB | 3.2 MB | compress, decompress |
| Sequencing | small | raw DEFLATE | `SRR389222_sub1.fastq.deflate` | 20.2 MB | 3.2 MB | compress, decompress |
| Sequencing | small | BGZF | `hapmap_3.pop_stratified_chr21.vcf.gz` | 11.5 MB | 2.5 MB | compress, decompress |
| Sequencing | medium | gzip | `DRR003897.fastq.gz` | 57.2 MB | 22.0 MB | compress, decompress |
| Sequencing | medium | zlib | `DRR003897.fastq.zlib` | 57.2 MB | 21.6 MB | compress, decompress |
| Sequencing | medium | raw DEFLATE | `DRR003897.fastq.deflate` | 57.2 MB | 21.6 MB | compress, decompress |
| Sequencing | medium | BGZF | `chr21.bam` | 76.2 MB | 12.9 MB | compress, decompress |
| Mass spectrometry | small | gzip | `55merge_tandem.mzid.gz` | 1.2 MB | 0.3 MB | compress, decompress |
| Mass spectrometry | small | zlib | `55merge_tandem.mzid.zlib` | 1.2 MB | 0.3 MB | compress, decompress |
| Mass spectrometry | small | raw DEFLATE | `55merge_tandem.mzid.deflate` | 1.2 MB | 0.3 MB | compress, decompress |
| Mass spectrometry | small | BGZF | `55merge_tandem.mzid.gz` | 1.2 MB | 0.3 MB | compress, decompress |
| Mass spectrometry | medium | gzip | `PRIDE_Exp_Complete_Ac_22134.xml.gz` | 48.0 MB | 10.7 MB | compress, decompress |
| Mass spectrometry | medium | zlib | `PRIDE_Exp_Complete_Ac_22134.xml.zlib` | 48.0 MB | 10.5 MB | compress, decompress |
| Mass spectrometry | medium | raw DEFLATE | `PRIDE_Exp_Complete_Ac_22134.xml.deflate` | 48.0 MB | 10.5 MB | compress, decompress |
| Mass spectrometry | medium | BGZF | `PRIDE_Exp_Complete_Ac_22134.xml.gz` | 48.0 MB | 11.3 MB | compress, decompress |
| General | small | gzip | `cantrbry.tar.gz` | 2.8 MB | 0.7 MB | compress, decompress |
| General | small | zlib | `cantrbry.tar.zlib` | 2.8 MB | 0.7 MB | compress, decompress |
| General | small | raw DEFLATE | `cantrbry.tar.deflate` | 2.8 MB | 0.7 MB | compress, decompress |
| General | small | BGZF | `cantrbry.tar.gz` | 2.8 MB | 0.8 MB | compress, decompress |
| General | medium | gzip | `silesia.tar.gz` | 211.9 MB | 68.2 MB | decompress |
| General | medium | zlib | `silesia.tar.zlib` | 211.9 MB | 68.6 MB | decompress |
| General | medium | raw DEFLATE | `silesia.tar.deflate` | 211.9 MB | 68.6 MB | decompress |
| General | medium | BGZF | `silesia.tar.gz` | 211.9 MB | 71.5 MB | decompress |

The gzip, zlib, and raw DEFLATE rows of a category compress the same plaintext; every decoder of a format reads the same file. The sequencing BGZF inputs are real BGZF files (a VCF and a BAM), so their plaintext differs from the FASTQ of the other formats. Sanity-class files (under 120 KB) are measured but left out of the summary, since process start-up dominates them.

## Method

- **Matched rounds.** All tools for one file and operation run in one Zebrac batch: 3 warmup rounds, then exactly 25 measured rounds, each round running every command once in a changing order. Load on the machine then slows every tool in the same rounds, which keeps the ratios fair. Times are medians of the 25 rounds.
- **Whole commands.** Each sample is a complete process: start-up, reading the input file, and writing the output to `/dev/null` (or to a pipe Zebrac discards). This is what a user running the command sees, not a library inner loop.
- **Correctness before timing.** Every tool was qualified on these files before it was timed: decoded bytes match an independent reference (GNU gzip, Python zlib, or a BGZF block walker that shares no code with zipir), and compressed output decodes back to the input with the reference decoder and with the tool itself. During the run, each compressor's output was decoded again and compared with the input.
- **Same inputs.** Every tool in a batch reads the same file; compression reads the plaintext from the page cache.
- **One thread.** Every tool runs single-threaded (`bgzip -@1`, no ISA-L threads); zipir is single-threaded by design.
- **Disturbed batches.** Other work on the machine can slow a block of rounds for every tool in a batch, which widens the spread of the 25 rounds. A batch where any tool's middle half of rounds spreads more than 6% (third quartile over first) is re-timed. In the 44 batches of this report the largest spread is 5.4%; none exceeds 6%.
- **Consistency.** zipir's results on the same stream in different containers must agree: raw DEFLATE against zlib decode of the same DEFLATE stream, and raw DEFLATE against zlib and gzip compression of the same plaintext (their checksums cost a few percent). This catches a batch slowed as a whole, which keeps a tight spread. Largest difference in this run: 4.8% over 36 pairs.
- **Re-timing.** Batches that failed either check were re-timed with `tools/bench.sh --force` before this report was generated; the tables show the re-timed values.

## Tools and versions

- **zipir** 0.1.2 at the commit above: the four `tools/` adapters (`zipir-gzip`, `-zlib`, `-deflate`, `-bgzf`), which import the library directly. Zig 0.16.0, ReleaseFast, `-Dcpu=native`, stripped, single-threaded.
- **zlib-ng** 2.3.3: the `minigzip` CLI for gzip; for zlib and raw DEFLATE, a small C adapter over its native API (`windowBits` 15 and -15). Static, `WITH_NATIVE_INSTRUCTIONS`, library defaults otherwise.
- **ISA-L igzip** 2.32.1: the `igzip` CLI, static, one thread, native build.
- **Zig std** 0.16.0: `std.compress.flate` through a Zig adapter, ReleaseFast, native CPU.
- **bgzip** from htslib 1.24, `-@1`: once with libdeflate 1.26 (static; the configuration bioconda ships) and once with zlib-ng 2.3.3 in zlib-compatible mode (static). htslib's default compiler flags; the codec libraries use native instructions.
- Every build targets this host's CPU (Zen 2: AVX2 is the widest vector extension available). A binary built here assumes AVX2; this report does not describe older x86-64 CPUs.

## Run conditions

- Host: AMD Ryzen 9 3950X, 32 logical CPUs, Linux 7.2.7-200.fc44.x86_64 x86_64, CPU governor `schedutil`. CPU flags include AVX2, BMI2, and PCLMULQDQ; there is no AVX-512 or VPCLMULQDQ.
- Every batch ran pinned to CPU 4 (`taskset -c 4`). The machine was in normal use: the 1-minute load average around the batches ranged from 1.1 to 6.6. Matched rounds keep that load from favoring one tool (see [Method](#method)).
- Zebrac 0.6.2, Zig 0.16.0, GCC 16.2.1. Files were in the page cache.

## Limits

- One machine, one CPU model. ARM64 and macOS are compile-tested only; their speed is not measured.
- Large files (about 125 MB to 235 MB compressed) are not in this run, and Silesia (generalized medium) is measured for decompression only: its level 9 compression by the slowest peers takes over an hour per batch.
- Peers outside this set (libdeflate's own CLI, GNU gzip, the host zlib, pigz, Rust flate2) passed the correctness checks on the sanity and small files but were not timed in this run.
- zipir has three levels; peers offer more. The curves compare three points per tool, not full frontiers.
- The results compare command-line tools, including start-up and file I/O; they do not rank library cores.

## Files

- [`measurements.tsv`](measurements.tsv): every timed row (file, tool, level, time quartiles, peak RSS, sizes, ratios against zipir, CPU cycles and instructions).
- [`summary.tsv`](summary.tsv): the values behind the summary figure and table.
- Generated by [`bench/report.py`](../report.py) from the `prime-lanes` run of [`tools/bench.sh`](../../tools/README.md).
