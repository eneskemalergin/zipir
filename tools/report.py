#!/usr/bin/env python3
"""Keyed comparison report for zipir tools.

Fact row key:
  host, tool, tool_version, format, operation, level, threads, nthreads,
  category, class, file

Compress JSON lives at
  zebrac/TOOL/FORMAT/LEVEL/THREADS/category.class.compress.json
Decompress JSON lives at
  zebrac/TOOL/FORMAT/-/THREADS/category.class.decompress.json
Legacy JSON at zebrac/TOOL/category.class.op.json is moved once.
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
LOCAL = TOOLS / ".local"
ZEBRAC = LOCAL / "zebrac"
QUALIFY = LOCAL / "qualify"
REPORT = LOCAL / "report"
README = TOOLS / "README.md"
PEERS = TOOLS / "peers.tsv"
COVERAGE = TOOLS / "coverage.tsv"
CORPUS = TOOLS / "corpus.tsv"
LEVELS = TOOLS / "levels.tsv"

ORACLE_BY_FORMAT = {
    "gzip": "gnu-gzip",
    "zlib": "system-zlib",
}
STORE_KEPT_PCT = 99.0
DEFAULT_KEPT_PP = 1.5
FAST_KEPT_PP = 3.0
SMALL_CATS = ("sequencing", "ms", "generalized")

FACTS_HEADER = [
    "host",
    "cpu",
    "nproc",
    "kernel",
    "tool",
    "tool_version",
    "format",
    "decode_mode",
    "operation",
    "level",
    "threads",
    "nthreads",
    "category",
    "class",
    "file",
    "uncompressed_bytes",
    "corpus_bytes",
    "tool_bytes",
    "peer_gzip6_bytes",
    "samples",
    "wall_median_ns",
    "wall_mean_ns",
    "rss_median_bytes",
    "throughput_mbs",
    "ratio",
    "kept_pct",
    "gzip6_kept_pct",
    "gzip1_kept_pct",
    "kept_pp_vs_gzip6",
    "gzip_rel",
    "gzip_rel_l6",
    "gzip_rel_l1",
    "rss_over_file",
    "encode_band",
    "json",
]

HEADLINE_HEADER = [
    "host",
    "tool",
    "tool_version",
    "format",
    "decode_mode",
    "level",
    "threads",
    "nthreads",
    "category",
    "class",
    "file",
    "uncompressed_bytes",
    "encode_mbs",
    "decode_mbs",
    "encode_ms",
    "decode_ms",
    "ratio",
    "kept_pct",
    "gzip6_kept_pct",
    "encode_rss_median_bytes",
    "decode_rss_median_bytes",
    "encode_gzip_rel_l6",
    "encode_gzip_rel_l1",
    "encode_gzip_rel_level",
    "decode_gzip_rel",
    "encode_rss_over_file",
    "decode_rss_over_file",
    "gzip1_kept_pct",
    "kept_pp_vs_gzip6",
    "encode_band",
]

GMEAN_HEADER = [
    "kind",
    "tool",
    "level",
    "band",
    "n",
    "gmean",
    "sequencing",
    "ms",
    "generalized",
]

MEASURED_TSV_HEADER = [
    "tool",
    "tool_version",
    "format",
    "decode_mode",
    "level",
    "threads",
    "nthreads",
    "category",
    "class",
    "file",
    "uncompressed_bytes",
    "corpus_bytes",
    "tool_bytes",
    "peer_gzip6_bytes",
    "samples",
    "encode_wall_median_ns",
    "decode_wall_median_ns",
    "encode_mbs",
    "decode_mbs",
    "ratio",
    "kept_pct",
    "gzip6_kept_pct",
    "gzip1_kept_pct",
    "kept_pp_vs_gzip6",
    "encode_rss_median_bytes",
    "decode_rss_median_bytes",
    "encode_gzip_rel_l6",
    "encode_gzip_rel_l1",
    "encode_gzip_rel_level",
    "decode_gzip_rel",
    "encode_rss_over_file",
    "decode_rss_over_file",
    "encode_band",
]

CLASS_ORDER = {"sanity": 0, "small": 1, "medium": 2, "large": 3}
CAT_ORDER = {"sequencing": 0, "ms": 1, "generalized": 2}


def oracle_for(fmt: str, operation: str = "decompress", decode_mode: str = "streaming") -> str | None:
    if operation == "decompress" and decode_mode != "streaming":
        return None
    return ORACLE_BY_FORMAT.get(fmt)


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read_tsv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    rows: list[dict[str, str]] = []
    header: list[str] | None = None
    for raw in path.read_text().splitlines():
        if not raw.strip() or raw.startswith("#"):
            continue
        cols = raw.split("\t")
        if header is None:
            header = cols
            continue
        if len(cols) < len(header):
            cols = cols + [""] * (len(header) - len(cols))
        rows.append(dict(zip(header, cols[: len(header)])))
    return rows


def read_meta(path: Path) -> dict[str, str]:
    meta: dict[str, str] = {}
    if not path.exists():
        return meta
    for raw in path.read_text().splitlines():
        if not raw.strip():
            continue
        key, _, val = raw.partition("\t")
        if key and key not in meta:
            meta[key] = val
    return meta


def write_tsv(path: Path, header: list[str], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["\t".join(header)]
    for row in rows:
        lines.append("\t".join(str(row.get(k, "")) for k in header))
    path.write_text("\n".join(lines) + "\n")


def md_table(headers: list[str], rows: list[list[str]], align_right: set[int] | None = None) -> str:
    align_right = align_right or set()
    sep = []
    for i, _ in enumerate(headers):
        sep.append("---:" if i in align_right else "---")
    out = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(sep) + " |",
    ]
    for row in rows:
        cells = list(row) + [""] * (len(headers) - len(row))
        out.append("| " + " | ".join(cells[: len(headers)]) + " |")
    return "\n".join(out)


def mbs(nbytes: int, ns: int) -> str:
    if not nbytes or not ns:
        return ""
    return f"{nbytes * 1000.0 / ns:.4f}"


def ratio(uncomp: int, comp: int) -> str:
    if not uncomp or not comp:
        return ""
    return f"{uncomp / comp:.4f}"


def kept(uncomp: int, comp: int) -> str:
    if not uncomp or not comp:
        return ""
    return f"{100.0 * comp / uncomp:.4f}"


def ffloat(s: str | None) -> float | None:
    if s is None or s == "":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def fmt_rel(num: float | None, den: float | None) -> str:
    if num is None or den is None or den <= 0 or num < 0:
        return ""
    return f"{num / den:.4f}"


def fmt_over(num: float | None, den: float | None) -> str:
    if num is None or den is None or den <= 0:
        return ""
    return f"{num / den:.4f}"


def fmt_pp(delta: float | None) -> str:
    if delta is None:
        return ""
    return f"{delta:.4f}"


def geometric_mean(values: list[float]) -> float | None:
    if not values or any(v <= 0 for v in values):
        return None
    return math.exp(sum(math.log(v) for v in values) / len(values))


def encode_band(
    kept_pct: float | None,
    gzip6_kept: float | None,
    gzip1_kept: float | None,
    *,
    store: bool,
) -> str:
    if store or (kept_pct is not None and kept_pct >= STORE_KEPT_PCT):
        return "store"
    d6 = None if kept_pct is None or gzip6_kept is None else abs(kept_pct - gzip6_kept)
    d1 = None if kept_pct is None or gzip1_kept is None else abs(kept_pct - gzip1_kept)
    in6 = d6 is not None and d6 <= DEFAULT_KEPT_PP
    in1 = d1 is not None and d1 <= FAST_KEPT_PP
    if in6 and in1:
        return "default" if d6 <= d1 else "fast"
    if in6:
        return "default"
    if in1:
        return "fast"
    return "out"


def fmt1(s: str) -> str:
    return "" if s == "" else f"{float(s):.1f}"


def fmt2(s: str) -> str:
    return "" if s == "" else f"{float(s):.2f}"


def ns_ms(ns: str) -> str:
    return "" if ns == "" else f"{int(ns) / 1e6:.2f}"


def human_bytes(n: int) -> str:
    if n >= 1048576:
        return f"{n / 1048576:.2f} MiB"
    if n >= 1024:
        return f"{n / 1024:.1f} KiB"
    return f"{n} B"


def human_rss(n: int) -> str:
    return f"{n / 1048576:.2f} MiB"


def sort_key(row: dict[str, str]) -> tuple:
    return (
        row.get("tool", ""),
        row.get("format", ""),
        row.get("level", ""),
        row.get("threads", ""),
        CAT_ORDER.get(row.get("category", ""), 99),
        CLASS_ORDER.get(row.get("class", ""), 99),
        row.get("file", ""),
        row.get("operation", ""),
    )


def load_peers() -> list[dict[str, str]]:
    rows = read_tsv(PEERS)
    if not rows:
        die(f"empty run matrix: {PEERS}")
    for row in rows:
        for key in ("tool", "tool_version", "format", "level", "threads", "nthreads"):
            if not row.get(key):
                die(f"{PEERS}: missing {key}")
        if row["threads"] not in ("ST", "MT"):
            die(f"{PEERS}: threads must be ST or MT, got {row['threads']}")
    return rows


def load_coverage() -> list[dict[str, str]]:
    rows = read_tsv(COVERAGE)
    if not rows:
        die(f"empty coverage matrix: {COVERAGE}")
    return rows


def coverage_for(coverage: list[dict[str, str]], peer: dict[str, str]) -> dict[str, str]:
    for row in coverage:
        if (
            row.get("tool") == peer.get("tool")
            and row.get("format") == peer.get("format")
            and row.get("tool_version") == peer.get("tool_version")
        ):
            return row
    return {}


def decode_mode_for(coverage: list[dict[str, str]], peer: dict[str, str]) -> str:
    row = coverage_for(coverage, peer)
    mode = row.get("decode_mode", "")
    if mode in ("streaming", "full-buffer"):
        return mode
    if row.get("stream") == "yes":
        return "streaming"
    if row.get("stream") in ("no", "hint"):
        return "full-buffer"
    return "unknown"


def load_corpus() -> list[dict[str, str]]:
    return read_tsv(CORPUS)


def load_levels() -> dict[str, dict[str, str]]:
    rows = read_tsv(LEVELS)
    if not rows:
        die(f"empty level table: {LEVELS}")
    out: dict[str, dict[str, str]] = {}
    for row in rows:
        tool = row.get("tool", "")
        if not tool:
            die(f"{LEVELS}: missing tool")
        for key in ("scale", "default", "full", "store", "fast"):
            if key not in row:
                die(f"{LEVELS}: {tool} missing {key}")
        if row["full"] == "-" and row["default"] == "-":
            out[tool] = row
            continue
        if not row["default"] or row["default"] in ("no", "-"):
            die(f"{LEVELS}: {tool} needs a default level")
        if not row["fast"] or row["fast"] in ("no", "-"):
            die(f"{LEVELS}: {tool} needs a fast level")
        full = set(row["full"].split())
        if row["default"] not in full:
            die(f"{LEVELS}: {tool} default {row['default']} not in full")
        if row["fast"] not in full:
            die(f"{LEVELS}: {tool} fast {row['fast']} not in full")
        store = row["store"]
        if store not in ("", "no") and store not in full:
            die(f"{LEVELS}: {tool} store {store} not in full")
        out[tool] = row
    return out


def is_store_level(levels: dict[str, dict[str, str]], tool: str, level: str) -> bool:
    store = levels.get(tool, {}).get("store", "no")
    return store not in ("", "no") and store == level


def load_sizes(tool: str) -> list[dict[str, str]]:
    rows = read_tsv(QUALIFY / tool / "sizes.tsv")
    out = []
    for row in rows:
        if "tool_bytes" not in row and "std_gzip_bytes" in row:
            row["tool_bytes"] = row["std_gzip_bytes"]
        if "peer_gzip6_bytes" not in row and "gzip6_bytes" in row:
            row["peer_gzip6_bytes"] = row["gzip6_bytes"]
        out.append(row)
    return out


def size_lookup(
    sizes: list[dict[str, str]],
    category: str,
    klass: str,
    filename: str = "",
    fmt: str = "",
    level: str = "",
    threads: str = "",
) -> dict[str, str]:
    for row in sizes:
        if row.get("category") != category or row.get("class") != klass:
            continue
        if filename and row.get("filename") not in ("", filename):
            continue
        if fmt and row.get("format") not in ("", fmt):
            continue
        if level and level != "-" and row.get("level") not in ("", level):
            continue
        if threads and row.get("threads") not in ("", threads):
            continue
        return row
    return {}


def peer_for(
    peers: list[dict[str, str]],
    tool: str,
    level: str = "",
    threads: str = "",
) -> dict[str, str]:
    for row in peers:
        if row["tool"] != tool:
            continue
        if threads and row["threads"] != threads:
            continue
        if level and level != "-" and row["level"] != level:
            continue
        return row
    return {}


def migrate_legacy(peers: list[dict[str, str]]) -> int:
    moved = 0
    if not ZEBRAC.exists():
        return 0
    for tool_dir in sorted(p for p in ZEBRAC.iterdir() if p.is_dir()):
        peer = peer_for(peers, tool_dir.name)
        fmt = peer.get("format", "gzip")
        clevel = peer.get("level", "6")
        threads = peer.get("threads", "ST")
        for path in list(tool_dir.glob("*.json")):
            parts = path.stem.split(".")
            if len(parts) != 3:
                continue
            category, klass, op = parts
            if op not in ("compress", "decompress"):
                continue
            level = clevel if op == "compress" else "-"
            dest = tool_dir / fmt / level / threads / f"{category}.{klass}.{op}.json"
            dest.parent.mkdir(parents=True, exist_ok=True)
            if dest.resolve() == path.resolve():
                continue
            if dest.exists():
                path.unlink()
                continue
            path.rename(dest)
            moved += 1
            print(f"migrate: {path} -> {dest}")
    return moved


def parse_json_file(path: Path, tool_dir: Path) -> dict[str, str] | None:
    rel = path.relative_to(tool_dir)
    parts = rel.parts
    if len(parts) != 4:
        return None
    fmt, level, threads, name = parts
    stem = Path(name).stem.split(".")
    if len(stem) != 3:
        return None
    category, klass, op = stem
    if op not in ("compress", "decompress"):
        return None
    data = json.loads(path.read_text())
    results = data.get("results") or []
    if not results:
        die(f"no results in {path}")
    r = results[0]
    failed = r.get("failed_sample_count", 0)
    if failed:
        die(f"{path} failed_sample_count={failed}")
    wall = r["wall_time"]
    rss = r["peak_rss"]
    return {
        "format": fmt,
        "level": level,
        "threads": threads,
        "category": category,
        "class": klass,
        "operation": op,
        "samples": str(r.get("sample_count", "")),
        "wall_median_ns": str(wall["median"]),
        "wall_mean_ns": str(wall["mean"]),
        "rss_median_bytes": str(rss["median"]),
        "json": str(path),
    }


def collect_facts(peers: list[dict[str, str]], coverage: list[dict[str, str]]) -> list[dict[str, str]]:
    facts: list[dict[str, str]] = []
    if not ZEBRAC.exists():
        return facts
    by_tool_peer = {p["tool"]: p for p in peers}
    for tool_dir in sorted(p for p in ZEBRAC.iterdir() if p.is_dir()):
        tool = tool_dir.name
        if tool not in by_tool_peer:
            continue
        peer = by_tool_peer[tool]
        decode_mode = decode_mode_for(coverage, peer)
        qmeta = read_meta(QUALIFY / tool / "meta.tsv")
        zmeta = read_meta(tool_dir / "meta.tsv")
        meta = {**qmeta, **zmeta}
        sizes = load_sizes(tool)
        nthreads = peer.get("nthreads", "1")
        for path in sorted(tool_dir.rglob("*.json")):
            parsed = parse_json_file(path, tool_dir)
            if parsed is None:
                if path.parent == tool_dir:
                    die(f"legacy JSON not migrated: {path}")
                continue
            sl = size_lookup(
                sizes,
                parsed["category"],
                parsed["class"],
                "",
                parsed["format"],
                parsed["level"] if parsed["operation"] == "compress" else "",
                parsed["threads"],
            )
            matched = peer_for(peers, tool, parsed["level"], parsed["threads"]) or peer
            filename = sl.get("filename", "")
            uncomp = int(sl.get("uncompressed_bytes") or 0)
            corpus = int(sl.get("corpus_bytes") or 0)
            tool_bytes = int(sl.get("tool_bytes") or 0)
            gzip6 = int(sl.get("peer_gzip6_bytes") or 0)
            ns = int(parsed["wall_median_ns"] or 0)
            row = {
                "host": meta.get("host", ""),
                "cpu": meta.get("cpu", ""),
                "nproc": meta.get("nproc", ""),
                "kernel": meta.get("kernel", ""),
                "tool": tool,
                "tool_version": matched.get("tool_version") or meta.get("tool_version", ""),
                "format": parsed["format"],
                "decode_mode": decode_mode,
                "operation": parsed["operation"],
                "level": parsed["level"],
                "threads": parsed["threads"],
                "nthreads": matched.get("nthreads", nthreads),
                "category": parsed["category"],
                "class": parsed["class"],
                "file": filename,
                "uncompressed_bytes": str(uncomp or ""),
                "corpus_bytes": str(corpus or ""),
                "tool_bytes": str(tool_bytes or ""),
                "peer_gzip6_bytes": str(gzip6 or ""),
                "samples": parsed["samples"],
                "wall_median_ns": parsed["wall_median_ns"],
                "wall_mean_ns": parsed["wall_mean_ns"],
                "rss_median_bytes": parsed["rss_median_bytes"],
                "throughput_mbs": mbs(uncomp, ns),
                "ratio": ratio(uncomp, tool_bytes) if parsed["operation"] == "compress" else "",
                "kept_pct": kept(uncomp, tool_bytes) if parsed["operation"] == "compress" else "",
                "gzip6_kept_pct": kept(uncomp, gzip6) if parsed["operation"] == "compress" else "",
                "gzip1_kept_pct": "",
                "kept_pp_vs_gzip6": "",
                "gzip_rel": "",
                "gzip_rel_l6": "",
                "gzip_rel_l1": "",
                "rss_over_file": "",
                "encode_band": "",
                "json": parsed["json"],
            }
            facts.append(row)
    facts.sort(key=sort_key)
    return facts


def wide_rows(facts: list[dict[str, str]], classes: set[str] | None = None) -> list[dict[str, str]]:
    decodes: dict[tuple, dict[str, str]] = {}
    compresses: list[dict[str, str]] = []
    for row in facts:
        if classes is not None and row["class"] not in classes:
            continue
        if row["operation"] == "decompress":
            key = (
                row["tool"],
                row["tool_version"],
                row["format"],
                row["threads"],
                row["nthreads"],
                row["category"],
                row["class"],
                row["file"],
                row["host"],
            )
            decodes[key] = row
        else:
            compresses.append(row)
    out: list[dict[str, str]] = []
    joined: set[tuple] = set()
    for enc in compresses:
        dkey = (
            enc["tool"],
            enc["tool_version"],
            enc["format"],
            enc["threads"],
            enc["nthreads"],
            enc["category"],
            enc["class"],
            enc["file"],
            enc["host"],
        )
        joined.add(dkey)
        dec = decodes.get(dkey, {})
        out.append(
            {
                "host": enc.get("host", ""),
                "tool": enc.get("tool", ""),
                "tool_version": enc.get("tool_version", ""),
                "format": enc.get("format", ""),
                "decode_mode": enc.get("decode_mode", "") or dec.get("decode_mode", ""),
                "level": enc.get("level", ""),
                "threads": enc.get("threads", ""),
                "nthreads": enc.get("nthreads", ""),
                "category": enc.get("category", ""),
                "class": enc.get("class", ""),
                "file": enc.get("file", ""),
                "uncompressed_bytes": enc.get("uncompressed_bytes", "") or dec.get("uncompressed_bytes", ""),
                "encode_mbs": enc.get("throughput_mbs", ""),
                "decode_mbs": dec.get("throughput_mbs", ""),
                "encode_ms": ns_ms(enc.get("wall_median_ns", "")),
                "decode_ms": ns_ms(dec.get("wall_median_ns", "")),
                "ratio": enc.get("ratio", ""),
                "kept_pct": enc.get("kept_pct", ""),
                "gzip6_kept_pct": enc.get("gzip6_kept_pct", ""),
                "gzip1_kept_pct": enc.get("gzip1_kept_pct", ""),
                "kept_pp_vs_gzip6": enc.get("kept_pp_vs_gzip6", ""),
                "encode_rss_median_bytes": enc.get("rss_median_bytes", ""),
                "decode_rss_median_bytes": dec.get("rss_median_bytes", ""),
                "encode_gzip_rel_l6": enc.get("gzip_rel_l6", ""),
                "encode_gzip_rel_l1": enc.get("gzip_rel_l1", ""),
                "encode_gzip_rel_level": enc.get("gzip_rel", ""),
                "decode_gzip_rel": dec.get("gzip_rel", ""),
                "encode_rss_over_file": enc.get("rss_over_file", ""),
                "decode_rss_over_file": dec.get("rss_over_file", ""),
                "encode_band": enc.get("encode_band", ""),
                "corpus_bytes": enc.get("corpus_bytes", "") or dec.get("corpus_bytes", ""),
                "tool_bytes": enc.get("tool_bytes", ""),
                "peer_gzip6_bytes": enc.get("peer_gzip6_bytes", "") or dec.get("peer_gzip6_bytes", ""),
                "samples": enc.get("samples") or dec.get("samples", ""),
                "encode_wall_median_ns": enc.get("wall_median_ns", ""),
                "decode_wall_median_ns": dec.get("wall_median_ns", ""),
            }
        )
    for dkey, dec in decodes.items():
        if dkey in joined:
            continue
        out.append(
            {
                "host": dec.get("host", ""),
                "tool": dec.get("tool", ""),
                "tool_version": dec.get("tool_version", ""),
                "format": dec.get("format", ""),
                "decode_mode": dec.get("decode_mode", ""),
                "level": "-",
                "threads": dec.get("threads", ""),
                "nthreads": dec.get("nthreads", ""),
                "category": dec.get("category", ""),
                "class": dec.get("class", ""),
                "file": dec.get("file", ""),
                "uncompressed_bytes": dec.get("uncompressed_bytes", ""),
                "encode_mbs": "",
                "decode_mbs": dec.get("throughput_mbs", ""),
                "encode_ms": "",
                "decode_ms": ns_ms(dec.get("wall_median_ns", "")),
                "ratio": "",
                "kept_pct": "",
                "gzip6_kept_pct": "",
                "gzip1_kept_pct": "",
                "kept_pp_vs_gzip6": "",
                "encode_rss_median_bytes": "",
                "decode_rss_median_bytes": dec.get("rss_median_bytes", ""),
                "encode_gzip_rel_l6": "",
                "encode_gzip_rel_l1": "",
                "encode_gzip_rel_level": "",
                "decode_gzip_rel": dec.get("gzip_rel", ""),
                "encode_rss_over_file": "",
                "decode_rss_over_file": dec.get("rss_over_file", ""),
                "encode_band": "",
                "corpus_bytes": dec.get("corpus_bytes", ""),
                "tool_bytes": "",
                "peer_gzip6_bytes": dec.get("peer_gzip6_bytes", ""),
                "samples": dec.get("samples", ""),
                "encode_wall_median_ns": "",
                "decode_wall_median_ns": dec.get("wall_median_ns", ""),
            }
        )
    out.sort(key=sort_key)
    return out


def oracle_index(facts: list[dict[str, str]]) -> dict[tuple[str, ...], dict[str, str]]:
    idx: dict[tuple[str, ...], dict[str, str]] = {}
    for row in facts:
        if row["tool"] != oracle_for(row["format"], row["operation"], row.get("decode_mode", "streaming")):
            continue
        key = (
            row["host"],
            row["format"],
            row["threads"],
            row["nthreads"],
            row["category"],
            row["class"],
            row["file"],
            row["operation"],
            row["level"],
        )
        if row["operation"] == "decompress":
            key += (row.get("decode_mode", "streaming"),)
        idx[key] = row
    return idx


def oracle_get(
    idx: dict[tuple[str, ...], dict[str, str]],
    row: dict[str, str],
    operation: str,
    level: str,
) -> dict[str, str] | None:
    key = (
        row["host"],
        row["format"],
        row["threads"],
        row["nthreads"],
        row["category"],
        row["class"],
        row["file"],
        operation,
        level,
    )
    if operation == "decompress":
        key += (row.get("decode_mode", "streaming"),)
    return idx.get(key)


def annotate_facts(facts: list[dict[str, str]], levels: dict[str, dict[str, str]]) -> None:
    idx = oracle_index(facts)
    for row in facts:
        rss = ffloat(row.get("rss_median_bytes"))
        uncomp = ffloat(row.get("uncompressed_bytes"))
        row["rss_over_file"] = fmt_over(rss, uncomp)
        mbs = ffloat(row.get("throughput_mbs"))
        if row["operation"] == "decompress":
            oracle = oracle_get(idx, row, "decompress", "-")
            row["gzip_rel"] = fmt_rel(mbs, ffloat(oracle.get("throughput_mbs") if oracle else None))
            continue
        kept_pct = ffloat(row.get("kept_pct"))
        gzip6 = oracle_get(idx, row, "compress", "6")
        gzip1 = oracle_get(idx, row, "compress", "1")
        same = oracle_get(idx, row, "compress", row["level"])
        gzip6_kept = ffloat(gzip6.get("kept_pct") if gzip6 else None)
        gzip1_kept = ffloat(gzip1.get("kept_pct") if gzip1 else None)
        if gzip6_kept is None:
            gzip6_kept = ffloat(row.get("gzip6_kept_pct"))
        row["gzip1_kept_pct"] = "" if gzip1_kept is None else f"{gzip1_kept:.4f}"
        row["gzip_rel"] = fmt_rel(mbs, ffloat(same.get("throughput_mbs") if same else None))
        row["gzip_rel_l6"] = fmt_rel(mbs, ffloat(gzip6.get("throughput_mbs") if gzip6 else None))
        row["gzip_rel_l1"] = fmt_rel(mbs, ffloat(gzip1.get("throughput_mbs") if gzip1 else None))
        if kept_pct is not None and gzip6_kept is not None:
            row["kept_pp_vs_gzip6"] = fmt_pp(kept_pct - gzip6_kept)
        row["encode_band"] = encode_band(
            kept_pct,
            gzip6_kept,
            gzip1_kept,
            store=is_store_level(levels, row["tool"], row["level"]),
        )


def rel_by_category(rows: list[dict[str, str]], key: str) -> dict[str, float]:
    out: dict[str, float] = {}
    for row in rows:
        val = ffloat(row.get(key))
        if val is None:
            continue
        out[row["category"]] = val
    return out


def gmean_record(kind: str, tool: str, level: str, band: str, rels: dict[str, float]) -> dict[str, str]:
    ordered = [rels[c] for c in SMALL_CATS if c in rels]
    g = geometric_mean(ordered)
    rec = {
        "kind": kind,
        "tool": tool,
        "level": level,
        "band": band,
        "n": str(len(ordered)),
        "gmean": "" if g is None else f"{g:.4f}",
        "sequencing": "" if "sequencing" not in rels else f"{rels['sequencing']:.4f}",
        "ms": "" if "ms" not in rels else f"{rels['ms']:.4f}",
        "generalized": "" if "generalized" not in rels else f"{rels['generalized']:.4f}",
    }
    return rec


def pick_level_rows(
    wide: list[dict[str, str]],
    tool: str,
    level: str,
    klass: str = "small",
) -> list[dict[str, str]]:
    return [
        r
        for r in wide
        if r["tool"] == tool and r["level"] == level and r["class"] == klass
    ]


def row_for_cat(rows: list[dict[str, str]], category: str) -> dict[str, str] | None:
    for row in rows:
        if row.get("category") == category:
            return row
    return None


def suite_rows(wide: list[dict[str, str]], levels: dict[str, dict[str, str]]) -> list[dict[str, str]]:
    small = [r for r in wide if r["class"] == "small"]
    tools = sorted({r["tool"] for r in small})
    out: list[dict[str, str]] = []
    for tool in tools:
        info = levels.get(tool, {})
        default = info.get("default", "")
        fast = info.get("fast", "")
        if default == "-":
            decode_rows = pick_level_rows(small, tool, "-")
            decode_rels = rel_by_category(decode_rows, "decode_gzip_rel")
            if decode_rels:
                out.append(gmean_record("decode", tool, "-", "", decode_rels))
            continue
        default_rows = pick_level_rows(small, tool, default) if default else []
        if default_rows:
            decode_rels = rel_by_category(default_rows, "decode_gzip_rel")
            if decode_rels:
                out.append(gmean_record("decode", tool, "-", "", decode_rels))
            seq = row_for_cat(default_rows, "sequencing")
            in_default = [r for r in default_rows if r.get("encode_band") == "default"]
            if seq and seq.get("encode_mbs") and seq.get("encode_band") == "default":
                default_rels = rel_by_category(in_default, "encode_gzip_rel_l6")
                if default_rels:
                    out.append(gmean_record("encode_default", tool, default, "default", default_rels))
            elif seq and seq.get("encode_mbs"):
                out.append(
                    gmean_record(
                        "encode_default_out",
                        tool,
                        default,
                        seq.get("encode_band", "out"),
                        rel_by_category(default_rows, "encode_gzip_rel_l6"),
                    )
                )
        if fast and fast != "-":
            fast_rows = pick_level_rows(small, tool, fast)
            seq_fast = row_for_cat(fast_rows, "sequencing")
            in_fast = [r for r in fast_rows if r.get("encode_band") == "fast"]
            if seq_fast and seq_fast.get("encode_mbs") and seq_fast.get("encode_band") == "fast":
                fast_rels = rel_by_category(in_fast, "encode_gzip_rel_l1")
                if fast_rels:
                    out.append(gmean_record("encode_fast", tool, fast, "fast", fast_rels))
    return out


def md_rel(s: str) -> str:
    return "" if s == "" else f"{float(s):.2f}x"


def md_over(s: str) -> str:
    return "" if s == "" else f"{float(s):.3f}"


def md_pp(s: str) -> str:
    if s == "":
        return ""
    val = float(s)
    return f"{val:+.1f}"


def cat_cells(rec: dict[str, str]) -> list[str]:
    return [md_rel(rec[c]) for c in SMALL_CATS]


def sort_gmean(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    def key(row: dict[str, str]) -> tuple:
        g = ffloat(row["gmean"])
        return (0 if g is not None else 1, -(g or 0.0), row["tool"])

    return sorted(rows, key=key)


def rss_default_rows(
    wide: list[dict[str, str]],
    levels: dict[str, dict[str, str]],
    coverage: list[dict[str, str]],
) -> list[list[str]]:
    bound = {r["tool"]: r.get("bound", "") for r in coverage}
    rows = []
    tools = sorted({r["tool"] for r in wide})
    for tool in tools:
        default = levels.get(tool, {}).get("default", "")
        match = [
            r
            for r in wide
            if r["tool"] == tool
            and r["class"] == "small"
            and r["category"] == "sequencing"
            and r["level"] == default
        ]
        if not match:
            continue
        r = match[0]
        enc_rss = r.get("encode_rss_median_bytes", "")
        dec_rss = r.get("decode_rss_median_bytes", "")
        rows.append(
            [
                f"`{tool}`",
                r.get("decode_mode", ""),
                default,
                fmt1(r.get("encode_mbs", "")),
                fmt1(r.get("decode_mbs", "")),
                human_rss(int(enc_rss)) if enc_rss else "",
                human_rss(int(dec_rss)) if dec_rss else "",
                md_over(r.get("encode_rss_over_file", "")),
                md_over(r.get("decode_rss_over_file", "")),
                bound.get(tool, ""),
            ]
        )
    return rows


def encode_detail_rows(rows: list[dict[str, str]], rel_key: str) -> list[list[str]]:
    by_tool: dict[str, list[dict[str, str]]] = {}
    for row in rows:
        by_tool.setdefault(row["tool"], []).append(row)
    recs = []
    for tool, group in by_tool.items():
        seq = row_for_cat(group, "sequencing")
        recs.append(
            (
                gmean_record(
                    "",
                    tool,
                    group[0]["level"],
                    (seq or group[0]).get("encode_band", ""),
                    rel_by_category(group, rel_key),
                ),
                seq,
            )
        )
    recs.sort(key=lambda item: (0 if item[0]["gmean"] else 1, -float(item[0]["gmean"] or 0), item[0]["tool"]))
    out = []
    for rec, seq in recs:
        out.append(
            [
                f"`{rec['tool']}`",
                rec["level"],
                (fmt1(seq.get("kept_pct", "")) + "%") if seq and seq.get("kept_pct") else "",
                md_pp(seq.get("kept_pp_vs_gzip6", "") if seq else ""),
                seq.get("encode_band", "") if seq else "",
                fmt1(seq.get("encode_mbs", "") if seq else ""),
                *cat_cells(rec),
                md_rel(rec["gmean"]),
                rec["n"],
            ]
        )
    return out


def normalized_markdown(
    facts: list[dict[str, str]],
    levels: dict[str, dict[str, str]],
    coverage: list[dict[str, str]],
) -> str:
    if not facts:
        return "_No Zebrac JSON yet. Run `tools/bench.sh` after qualify._"
    wide = wide_rows(facts)
    small = [r for r in wide if r["class"] == "small"]
    if not small:
        return "_No `class=small` facts yet._"
    suite = suite_rows(small, levels)
    decode = sort_gmean([r for r in suite if r["kind"] == "decode"])
    encode_out = sort_gmean([r for r in suite if r["kind"] == "encode_default_out"])
    meta = facts[0]
    oracle_text = ", ".join(
        f"{fmt} streaming=`{name}`" for fmt, name in sorted(ORACLE_BY_FORMAT.items())
    )
    lines = [
        f"- Host: {meta['host']}. Streaming decode oracles: {oracle_text}. `class=small` only.",
        f"- Store if kept >= {STORE_KEPT_PCT:g}% or this tool's store level. Default band: `|kept - gzip -6 kept| <= {DEFAULT_KEPT_PP:g}` pp. Fast band: `|kept - gzip -1 kept| <= {FAST_KEPT_PP:g}` pp. Closer oracle wins if both match.",
        "- Oracle-relative throughput is this tool's uncompressed MB/s divided by the oracle for the same format, decode mode, file, threads, and host. Full-buffer decode rows have no oracle-relative ranking unless a matching full-buffer oracle is added. Decode has no level. Gzip encode vs `-6` ranks only inside the default band. Gzip encode vs `-1` ranks only inside the fast band.",
        "- Geometric mean is over the small files in that band. Encode ranking tables require the sequencing file in-band; other files can drop out (`n` < 3). Tool defaults whose sequencing kept is not gzip `-6` go to the out table, not the default-ratio ranking.",
        "- RSS / file is peak RSS / uncompressed bytes. Do not rank by MB/s per MiB RSS.",
        "",
        "#### Decode oracle-relative throughput",
        "",
    ]
    lines.append(
        md_table(
            ["Tool", "Sequencing", "MS", "Generalized", "gmean", "n"],
            [
                [f"`{r['tool']}`", *cat_cells(r), md_rel(r["gmean"]), r["n"]]
                for r in decode
            ],
            align_right={1, 2, 3, 4, 5},
        )
    )
    lines += [
        "",
        "#### Encode, gzip -6 kept band",
        "",
        "Each tool at its `levels.tsv` default. Sequencing kept must be in the gzip `-6` band. Rel is vs gzip `-6`. Kept and MB/s are the sequencing file. A blank category is a small file outside the band.",
        "",
    ]
    default_tools = {r["tool"] for r in suite if r["kind"] == "encode_default"}
    fast_tools = {r["tool"] for r in suite if r["kind"] == "encode_fast"}
    out_tools = {r["tool"] for r in encode_out}
    encode_headers = [
        "Tool",
        "Level",
        "Kept",
        "vs gzip -6",
        "Band",
        "Encode MB/s",
        "Sequencing",
        "MS",
        "Generalized",
        "gmean",
        "n",
    ]
    encode_align = {1, 2, 3, 5, 6, 7, 8, 9, 10}
    default_files = [
        r
        for r in small
        if r["tool"] in default_tools
        and levels.get(r["tool"], {}).get("default") == r["level"]
        and r.get("encode_band") == "default"
    ]
    lines.append(
        md_table(
            encode_headers,
            encode_detail_rows(default_files, "encode_gzip_rel_l6"),
            align_right=encode_align,
        )
    )
    lines += [
        "",
        "#### Encode, gzip -1 kept band",
        "",
        "Each tool at its `levels.tsv` fast level. Sequencing kept must be in the gzip `-1` band. Rel is vs gzip `-1`. zlib-ng / zlib-rs `-1` is fatter than this band and is not here.",
        "",
    ]
    fast_files = [
        r
        for r in small
        if r["tool"] in fast_tools
        and levels.get(r["tool"], {}).get("fast") == r["level"]
        and r.get("encode_band") == "fast"
    ]
    lines.append(
        md_table(
            encode_headers,
            encode_detail_rows(fast_files, "encode_gzip_rel_l1"),
            align_right=encode_align,
        )
    )
    lines += [
        "",
        "#### Encode, tool default outside gzip -6 band",
        "",
        "Not a ranking. Tool default whose sequencing kept is not in the gzip `-6` band. Rel vs gzip `-6` is shown for all three small files. igzip `-2` lives here.",
        "",
    ]
    if out_tools:
        out_files = [
            r
            for r in small
            if r["tool"] in out_tools and levels.get(r["tool"], {}).get("default") == r["level"]
        ]
        lines.append(
            md_table(
                encode_headers,
                encode_detail_rows(out_files, "encode_gzip_rel_l6"),
                align_right=encode_align,
            )
        )
    else:
        lines.append("_None on this host._")
    lines += [
        "",
        "#### RSS at tool default, sequencing small",
        "",
    ]
    lines.append(
        md_table(
            [
                "Tool",
                "Decode mode",
                "Level",
                "Encode MB/s",
                "Decode MB/s",
                "Encode RSS",
                "Decode RSS",
                "Enc RSS/file",
                "Dec RSS/file",
                "Bound",
            ],
            rss_default_rows(small, levels, coverage),
            align_right={2, 3, 4, 5, 6, 7, 8},
        )
    )
    return "\n".join(lines)


def write_per_tool(facts: list[dict[str, str]]) -> None:
    tools = sorted({r["tool"] for r in facts})
    for tool in tools:
        subset = [r for r in facts if r["tool"] == tool]
        zdir = ZEBRAC / tool
        summary_rows = []
        for row in subset:
            summary_rows.append(
                {
                    "category": row["category"],
                    "class": row["class"],
                    "op": row["operation"],
                    "format": row["format"],
                    "decode_mode": row["decode_mode"],
                    "level": row["level"],
                    "threads": row["threads"],
                    "samples": row["samples"],
                    "wall_median_ns": row["wall_median_ns"],
                    "wall_mean_ns": row["wall_mean_ns"],
                    "rss_median_bytes": row["rss_median_bytes"],
                    "json": row["json"],
                }
            )
        write_tsv(
            zdir / "summary.tsv",
            [
                "category",
                "class",
                "op",
                "format",
                "decode_mode",
                "level",
                "threads",
                "samples",
                "wall_median_ns",
                "wall_mean_ns",
                "rss_median_bytes",
                "json",
            ],
            summary_rows,
        )
        wide = wide_rows(subset)
        write_tsv(zdir / "measured.tsv", MEASURED_TSV_HEADER, wide)


def inject(readme: str, name: str, body: str) -> str:
    begin = f"<!-- generated:{name} -->"
    end = f"<!-- /generated:{name} -->"
    if begin not in readme or end not in readme:
        die(f"missing README markers {begin} .. {end}")
    pre, rest = readme.split(begin, 1)
    _, post = rest.split(end, 1)
    block = body.strip("\n")
    return f"{pre}{begin}\n{block}\n{end}{post}"


def coverage_tables(coverage: list[dict[str, str]]) -> dict[str, str]:
    work_rows = []
    shape_rows = []
    integ_rows = []
    for row in coverage:
        name = f"`{row['tool']}`"
        work_rows.append(
            [
                name,
                row["format"],
                row["compress"],
                row["decompress"],
                row["levels"],
                row["st"],
                row["mt"],
            ]
        )
        shape_rows.append(
            [name, row["decode_mode"], row["stream"], row["bound"], row["window"], row["heap"]]
        )
        integ_rows.append(
            [name, row["crc"], row["isize"], row["concat"], row["cap"], row["dict"]]
        )
    return {
        "work": md_table(
            ["Tool", "Format", "Compress", "Decompress", "Level", "ST", "MT"],
            work_rows,
        ),
        "shape": md_table(
            ["Tool", "Decode mode", "Stream", "Bound", "Window", "Heap"], shape_rows
        ),
        "integrity": md_table(
            ["Tool", "CRC", "ISIZE", "Concat", "Cap", "Dict"],
            integ_rows,
        ),
    }


def measured_markdown(facts: list[dict[str, str]], peers: list[dict[str, str]]) -> str:
    if not facts:
        return "_No Zebrac JSON yet. Run `tools/bench.sh` after qualify._"
    wide = wide_rows(facts)
    meta_row = facts[0]
    tools = sorted({r["tool"] for r in facts})
    named = ", ".join(f"`{t}`" for t in tools)
    lines = [
        f"- Host: {meta_row['host']}, {meta_row['cpu']}, {meta_row['kernel']}",
        f"- Tools: {named}. Formats and threads are shown per row. Compress levels are per tool in the tables.",
        "- Zebrac 0.6.2: `-w 3 -i 25 -a 25`, sink `/dev/null`, no `-f`",
        "- **Encode MB/s** / **Decode MB/s:** uncompressed bytes / median wall seconds / `10^6`. Same work unit for both directions.",
        "- **Ratio:** uncompressed / this tool's compressed bytes. Higher is more compression.",
        "- **Kept:** compressed / uncompressed as a percent. Lower is more compression.",
        "- **gzip -6 kept:** host `gzip -6` on the same plaintext for gzip rows.",
        "- **Oracle-relative throughput:** this tool's MB/s divided by the oracle for the same format and decode mode on the same file. Full-buffer rows are shown with absolute speed and RSS, but are not ranked with streaming rows.",
        "- **RSS / file:** peak RSS / uncompressed bytes. **Band:** store / default / fast / out from kept vs gzip `-6` and gzip `-1`; decode-only rows have no band.",
        "- **RSS:** Zebrac peak RSS median.",
        "- Sanity files are tens to hundreds of KiB. Those MB/s numbers are startup-heavy. Small is the class that actually times the codec. Headline views filter `class=small`. Normalized tables above use small only.",
        "",
        "Machine-readable copies: `tools/.local/report/facts.tsv` (long, one row per key), `headline.tsv` (`class=small`, encode and decode joined), and `gmean.tsv` (suite oracle-relative throughput). Per-tool `summary.tsv` and `measured.tsv` stay under `tools/.local/zebrac/TOOL/`.",
        "",
        "#### Headline (`class=small`)",
        "",
    ]
    small = [r for r in wide if r["class"] == "small"]
    lines.append(
        md_table(
            [
                "Tool",
                "Format",
                "Decode mode",
                "Level",
                "Threads",
                "Category",
                "File",
                "Encode MB/s",
                "Decode MB/s",
                "Ratio",
                "Kept",
                "Oracle-rel vs -6",
                "Decode oracle-rel",
                "Enc RSS/file",
                "Band",
                "Encode RSS",
                "Decode RSS",
            ],
            [
                [
                    f"`{r['tool']}`",
                    r["format"],
                    r["decode_mode"],
                    r["level"],
                    r["threads"],
                    r["category"],
                    f"`{r['file']}`" if r["file"] else "",
                    fmt1(r["encode_mbs"]),
                    fmt1(r["decode_mbs"]),
                    (fmt2(r["ratio"]) + "x") if r["ratio"] else "",
                    (fmt1(r["kept_pct"]) + "%") if r["kept_pct"] else "",
                    md_rel(r.get("encode_gzip_rel_l6", "")),
                    md_rel(r.get("decode_gzip_rel", "")),
                    md_over(r.get("encode_rss_over_file", "")),
                    r.get("encode_band", ""),
                    human_rss(int(r["encode_rss_median_bytes"])) if r["encode_rss_median_bytes"] else "",
                    human_rss(int(r["decode_rss_median_bytes"])) if r["decode_rss_median_bytes"] else "",
                ]
                for r in small
            ],
            align_right={3, 7, 8, 9, 10, 11, 12, 13, 15, 16},
        )
    )
    thru_headers = [
        "Tool",
        "Decode mode",
        "Level",
        "Category",
        "Class",
        "File",
        "Uncomp",
        "Encode MB/s",
        "Encode ms",
        "Decode MB/s",
        "Decode ms",
        "Encode RSS",
        "Decode RSS",
    ]

    def thru_rows(src: list[dict[str, str]]) -> list[list[str]]:
        rows = []
        for r in src:
            uncomp = int(r["uncompressed_bytes"] or 0)
            rows.append(
                [
                    f"`{r['tool']}`",
                    r["decode_mode"],
                    r["level"],
                    r["category"],
                    r["class"],
                    f"`{r['file']}`" if r["file"] else "",
                    human_bytes(uncomp) if uncomp else "",
                    fmt1(r["encode_mbs"]),
                    r["encode_ms"],
                    fmt1(r["decode_mbs"]),
                    r["decode_ms"],
                    human_rss(int(r["encode_rss_median_bytes"])) if r["encode_rss_median_bytes"] else "",
                    human_rss(int(r["decode_rss_median_bytes"])) if r["decode_rss_median_bytes"] else "",
                ]
            )
        return rows

    lines += ["", "#### Codec throughput (`class=small`)", ""]
    lines.append(md_table(thru_headers, thru_rows(small), align_right={2, 6, 7, 8, 9, 10, 11, 12}))
    sanity = [r for r in wide if r["class"] == "sanity"]
    if sanity:
        lines += ["", "#### Startup throughput (`class=sanity`)", ""]
        lines.append(md_table(thru_headers, thru_rows(sanity), align_right={2, 6, 7, 8, 9, 10, 11, 12}))
    other = [r for r in wide if r["class"] not in ("small", "sanity")]
    if other:
        lines += ["", "#### Other classes", ""]
        lines.append(md_table(thru_headers, thru_rows(other), align_right={2, 6, 7, 8, 9, 10, 11, 12}))
    lines += ["", "#### Compression", ""]
    comp = []
    for r in wide:
        uncomp = r["uncompressed_bytes"]
        comp.append(
            [
                f"`{r['tool']}`",
                r["level"],
                r["category"],
                r["class"],
                f"`{r['file']}`" if r["file"] else "",
                uncomp,
                r["corpus_bytes"],
                r["tool_bytes"],
                (fmt2(r["ratio"]) + "x") if r["ratio"] else "",
                (fmt1(r["kept_pct"]) + "%") if r["kept_pct"] else "",
                r["peer_gzip6_bytes"],
                (fmt1(r["gzip6_kept_pct"]) + "%") if r["gzip6_kept_pct"] else "",
            ]
        )
    lines.append(
        md_table(
            [
                "Tool",
                "Level",
                "Category",
                "Class",
                "File",
                "Uncomp B",
                "Corpus gz",
                "Tool bytes",
                "Ratio",
                "Kept",
                "gzip -6",
                "gzip -6 kept",
            ],
            comp,
            align_right={1, 5, 6, 7, 8, 9, 10, 11},
        )
    )
    lines += [
        "",
        "Ratio and kept use the qualify compress write size, not Zebrac (Zebrac discards output to `/dev/null`). Corpus gz is the downloaded file, which was not necessarily produced by this tool or by host `gzip -6`.",
    ]
    return "\n".join(lines)


def expected_json(peers: list[dict[str, str]], corpus: list[dict[str, str]], classes: set[str]) -> list[Path]:
    paths: list[Path] = []
    seen: set[Path] = set()

    def add(path: Path) -> None:
        if path not in seen:
            seen.add(path)
            paths.append(path)

    for peer in peers:
        tool = peer["tool"]
        fmt = peer["format"]
        threads = peer["threads"]
        files = [c for c in corpus if c["class"] in classes and c["format"] == fmt]
        for item in files:
            cat, klass = item["category"], item["class"]
            if peer["level"] != "-":
                add(
                    ZEBRAC
                    / tool
                    / fmt
                    / peer["level"]
                    / threads
                    / f"{cat}.{klass}.compress.json"
                )
            add(
                ZEBRAC
                / tool
                / fmt
                / "-"
                / threads
                / f"{cat}.{klass}.decompress.json"
            )
    return paths


def check_encode_band() -> int:
    cases = [
        (16.3, 16.3, 22.1, False, "default"),
        (16.9, 16.3, 22.1, False, "default"),
        (17.8, 16.3, 22.1, False, "default"),
        (20.3, 16.3, 22.1, False, "fast"),
        (24.4, 16.3, 22.1, False, "fast"),
        (19.1, 16.3, 22.1, False, "fast"),
        (25.1, 16.3, 22.1, False, "fast"),
        (27.4, 16.3, 22.1, False, "out"),
        (100.0, 16.3, 22.1, True, "store"),
        (100.0, 16.3, 22.1, False, "store"),
    ]
    errors = 0
    for kept_pct, gzip6, gzip1, store, want in cases:
        got = encode_band(kept_pct, gzip6, gzip1, store=store)
        if got != want:
            print(
                f"error: encode_band({kept_pct}, {gzip6}, {gzip1}, store={store})={got} want {want}",
                file=sys.stderr,
            )
            errors += 1
    return errors


def check(
    peers: list[dict[str, str]],
    coverage: list[dict[str, str]],
    facts: list[dict[str, str]],
    levels: dict[str, dict[str, str]],
    require_json: bool,
) -> int:
    errors = check_encode_band()
    cov_keys = {(r["tool"], r["format"], r["tool_version"]) for r in coverage}
    for peer in peers:
        key = (peer["tool"], peer["format"], peer["tool_version"])
        if key not in cov_keys:
            print(f"error: peers row has no coverage: {key}", file=sys.stderr)
            errors += 1
        if peer["tool"] not in levels:
            print(f"error: peers tool has no levels.tsv row: {peer['tool']}", file=sys.stderr)
            errors += 1
    corpus = load_corpus()
    want = expected_json(peers, corpus, {"sanity", "small"})
    if require_json:
        for path in want:
            if not path.exists():
                print(f"error: missing JSON for default classes: {path}", file=sys.stderr)
                errors += 1
    if (LOCAL / "plain").exists():
        print("error: uncompressed cache exists at tools/.local/plain", file=sys.stderr)
        errors += 1
    allowed_op = {"compress", "decompress"}
    allowed_thr = {"ST", "MT"}
    allowed_cls = {"sanity", "small", "medium", "large"}
    allowed_decode_mode = {"streaming", "full-buffer"}
    for row in facts:
        if row["operation"] not in allowed_op:
            print(f"error: bad operation {row['operation']}", file=sys.stderr)
            errors += 1
        if row["threads"] not in allowed_thr:
            print(f"error: bad threads {row['threads']}", file=sys.stderr)
            errors += 1
        if row["class"] not in allowed_cls:
            print(f"error: bad class {row['class']}", file=sys.stderr)
            errors += 1
        if row.get("decode_mode") not in allowed_decode_mode:
            print(f"error: bad decode mode {row.get('decode_mode')}: {row['json']}", file=sys.stderr)
            errors += 1
        if row["operation"] == "decompress" and row["level"] != "-":
            print(f"error: decompress level must be -: {row['json']}", file=sys.stderr)
            errors += 1
        if row["operation"] == "compress" and row["level"] == "-":
            print(f"error: compress level must not be -: {row['json']}", file=sys.stderr)
            errors += 1
        if (
            row["tool"]
            == oracle_for(row["format"], row["operation"], row.get("decode_mode", "streaming"))
            and row["class"] == "small"
        ):
            if row["operation"] == "decompress" and row.get("gzip_rel") != "1.0000":
                print(f"error: {row['tool']} {row['format']} decode oracle-relative value must be 1.0000: {row['json']}", file=sys.stderr)
                errors += 1
            if row["format"] == "gzip" and row["operation"] == "compress" and row["level"] == "6":
                if row.get("gzip_rel") != "1.0000" or row.get("gzip_rel_l6") != "1.0000":
                    print(f"error: {row['tool']} gzip -6 oracle-relative value must be 1.0000: {row['json']}", file=sys.stderr)
                    errors += 1
                if row.get("encode_band") != "default":
                    print(f"error: {row['tool']} gzip -6 band must be default: {row['json']}", file=sys.stderr)
                    errors += 1
            if row["format"] == "gzip" and row["operation"] == "compress" and row["level"] == "1" and row.get("encode_band") != "fast":
                print(f"error: {row['tool']} gzip -1 band must be fast: {row['json']}", file=sys.stderr)
                errors += 1
    small = wide_rows(facts, {"small"})
    for rec in suite_rows(small, levels):
        if rec["tool"] in ORACLE_BY_FORMAT.values() and rec["kind"] in ("decode", "encode_default", "encode_fast"):
            if rec.get("gmean") != "1.0000":
                print(f"error: {rec['tool']} {rec['kind']} gmean must be 1.0000, got {rec.get('gmean')}", file=sys.stderr)
                errors += 1
        if rec["kind"] in ("encode_default", "encode_fast"):
            want_band = "default" if rec["kind"] == "encode_default" else "fast"
            level = levels.get(rec["tool"], {}).get(want_band, "")
            seq = next(
                (
                    r
                    for r in small
                    if r["tool"] == rec["tool"]
                    and r["level"] == level
                    and r["category"] == "sequencing"
                ),
                None,
            )
            if seq is None or seq.get("encode_band") != want_band:
                print(
                    f"error: {rec['kind']} {rec['tool']} sequencing band {seq.get('encode_band') if seq else None} want {want_band}",
                    file=sys.stderr,
                )
                errors += 1
    if errors:
        print(f"report check: {errors} error(s)", file=sys.stderr)
        return 1
    print(f"report check: ok facts={len(facts)} json_default={len(want)} require_json={require_json}")
    return 0


def main() -> int:
    args = sys.argv[1:]
    check_only = False
    if args in ([],):
        pass
    elif args == ["--check"]:
        check_only = True
    elif args in (["--help"], ["-h"]):
        print("usage: tools/report.py [--check]")
        return 0
    else:
        die("usage: tools/report.py [--check]")

    peers = load_peers()
    coverage = load_coverage()
    levels = load_levels()
    moved = migrate_legacy(peers)
    if moved:
        print(f"migrated {moved} legacy JSON file(s)")
    facts = collect_facts(peers, coverage)
    annotate_facts(facts, levels)
    REPORT.mkdir(parents=True, exist_ok=True)
    write_tsv(REPORT / "facts.tsv", FACTS_HEADER, facts)
    small = wide_rows(facts, {"small"})
    write_tsv(REPORT / "headline.tsv", HEADLINE_HEADER, small)
    write_tsv(REPORT / "gmean.tsv", GMEAN_HEADER, suite_rows(small, levels))
    write_per_tool(facts)
    if README.exists():
        tables = coverage_tables(coverage)
        measured = measured_markdown(facts, peers)
        normalized = normalized_markdown(facts, levels, coverage)
        readme = README.read_text()
        readme = inject(readme, "work", tables["work"])
        readme = inject(readme, "shape", tables["shape"])
        readme = inject(readme, "integrity", tables["integrity"])
        readme = inject(readme, "normalized", normalized)
        readme = inject(readme, "measured", measured)
        README.write_text(readme)
    print(f"report: {REPORT / 'facts.tsv'} rows={len(facts)}")
    print(f"report: {REPORT / 'gmean.tsv'}")
    if README.exists():
        print(f"report: {README}")
    return check(peers, coverage, facts, levels, require_json=check_only)


if __name__ == "__main__":
    raise SystemExit(main())
