#!/usr/bin/env python3
"""Summarize matched tools/bench.sh batches against the zipir anchor in each batch.

usage: tools/report.py [--check] [RUN]

RUN is a directory under tools/.local/bench/ (default prime-lanes). Writes
tools/.local/report/RUN/facts.tsv (one row per file, operation, tool, and level) and
summary.md (lane table and per-file tables), and prints the lane tables. --check only
validates the batches and exits non-zero on any problem.
"""
import json
import math
import re
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
BENCH = TOOLS / ".local" / "bench"
REPORT = TOOLS / ".local" / "report"
CLASS_ORDER = {"sanity": 0, "small": 1, "medium": 2, "large": 3}
FACTS = [
    "format", "op", "category", "class", "file", "tool", "level", "lane", "decode", "samples",
    "wall_median_ns", "wall_q1_ns", "wall_q3_ns", "rss_median_bytes", "plain_bytes", "input_bytes",
    "compressed_bytes", "mbs", "ratio", "time_vs_zipir", "size_vs_zipir", "rss_vs_zipir",
    "load_before", "load_after", "commit", "dirty",
]


def die(message):
    sys.exit(f"error: {message}")


def peer_order():
    names = []
    for line in (TOOLS / "peers.tsv").read_text().splitlines():
        if line and not line.startswith("#") and not line.startswith("tool\t"):
            names.append(line.split("\t")[0])
    return {name: i for i, name in enumerate(names)}


def read_batch(tsv):
    """Returns (meta, subject rows) from a batch .tsv written by bench.sh."""
    meta, rows, header = {}, [], None
    for line in tsv.read_text().splitlines():
        if line.startswith("# "):
            key, _, value = line[2:].partition("\t")
            meta[key] = value
        elif header is None:
            header = line.split("\t")
        elif line:
            rows.append(dict(zip(header, line.split("\t"))))
    return meta, rows


def load(run):
    """All batches of a run as fact rows, plus a list of problems."""
    facts, problems, anchors = [], [], {}
    base = BENCH / run
    if not base.is_dir():
        die(f"no bench results for {run}: {base}")
    for tsv in sorted(p for p in base.glob("*/*/*.tsv") if not p.name.endswith(".part.tsv")):
        json_path = tsv.with_suffix(".json")
        if not json_path.exists():
            problems.append(f"{tsv}: no matching .json")
            continue
        meta, subjects = read_batch(tsv)
        results = json.loads(json_path.read_text())["results"]
        if len(results) != len(subjects):
            problems.append(f"{json_path}: {len(results)} results for {len(subjects)} subjects")
            continue
        rounds = int(meta.get("rounds", 25))
        bad = [r["command"] for r in results if r["sample_count"] != rounds or r["failed_sample_count"] != 0]
        if bad:
            problems.append(f"{json_path}: incomplete samples for {bad}")
            continue
        batch = []
        for subject, result in zip(subjects, results):
            wall, rss = result["wall_time"], result["peak_rss"]
            plain = int(meta["plain_bytes"])
            comp = int(subject["compressed_bytes"])
            batch.append({
                "format": meta["format"], "op": meta["op"], "category": meta["category"],
                "class": meta["class"], "file": Path(meta["input"]).name, **subject,
                "samples": result["sample_count"], "wall_median_ns": wall["median"],
                "wall_q1_ns": wall["q1"], "wall_q3_ns": wall["q3"], "rss_median_bytes": rss["median"],
                "plain_bytes": plain, "input_bytes": int(meta["input_bytes"]), "compressed_bytes": comp,
                "mbs": plain / (wall["median"] / 1e9) / 1e6, "ratio": plain / comp if comp else None,
                "load_before": meta["load_before"], "load_after": meta["load_after"],
                "commit": meta["commit"][:12], "dirty": meta["dirty"],
            })
        anchor_tool = f"zipir-{meta['format']}"
        # The batch key names each subject's binary (path, size, mtime); one run must use one zipir.
        for identity in re.findall(rf"; {anchor_tool} \S+ \S+ (\S+ \d+ \d+)", meta.get("key", "")):
            anchors.setdefault(anchor_tool, set()).add(identity)
        if not any(a["tool"] == anchor_tool for a in batch):
            problems.append(f"{json_path}: no {anchor_tool} anchor in the batch")
        for row in batch:
            # Decode rows compare with zipir's decode; compress rows with zipir's level in the same lane.
            anchor = next((a for a in batch if a["tool"] == anchor_tool and
                           (meta["op"] == "decompress" or (row["lane"] != "-" and a["lane"] == row["lane"]))), None)
            if anchor is None and (meta["op"] == "decompress" or row["lane"] != "-"):
                problems.append(f"{json_path}: no {anchor_tool} {row['lane']} row for {row['tool']} {row['level']}")
            row["time_vs_zipir"] = row["wall_median_ns"] / anchor["wall_median_ns"] if anchor else None
            row["size_vs_zipir"] = (row["compressed_bytes"] / anchor["compressed_bytes"]
                                    if anchor and meta["op"] == "compress" else None)
            row["rss_vs_zipir"] = row["rss_median_bytes"] / anchor["rss_median_bytes"] if anchor else None
        facts.extend(batch)
    for tool, identities in anchors.items():
        if len(identities) > 1:
            problems.append(f"{base}: batches use {len(identities)} different {tool} binaries; "
                            f"re-run tools/bench.sh with the same selection and --force")
    if not facts and not problems:
        problems.append(f"{base}: no batches")
    order = peer_order()
    facts.sort(key=lambda r: (r["format"], r["op"], r["category"], CLASS_ORDER[r["class"]],
                              order.get(r["tool"], 99), -1 if r["level"] == "-" else int(r["level"])))
    return facts, problems


def num(value, digits):
    return "" if value is None else f"{value:.{digits}f}"


def gmean(values):
    values = [v for v in values if v]
    return math.exp(sum(map(math.log, values)) / len(values)) if values else None


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join(" --- " for _ in header) + "|"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def lane_table(rows):
    """Geometric means over files, one line per tool and level; ranges for absolute numbers."""
    groups = {}
    for r in rows:
        groups.setdefault((r["tool"], r["level"]), []).append(r)
    out = []
    for (tool, level), items in groups.items():
        mbs = [r["mbs"] for r in items]
        rss = [r["rss_median_bytes"] / 1048576 for r in items]
        out.append([f"**{tool}**" if tool.startswith("zipir") else tool, items[0]["lane"], level,
                    items[0]["decode"], len(items), num(gmean([r["time_vs_zipir"] for r in items]), 2),
                    num(gmean([r["size_vs_zipir"] for r in items]), 3),
                    num(gmean([r["rss_vs_zipir"] for r in items]), 2),
                    f"{min(mbs):.1f} to {max(mbs):.1f}", f"{min(rss):.1f} to {max(rss):.1f}"])
    return table(["tool", "lane", "level", "decode", "files", "time vs zipir", "size vs zipir",
                  "RSS vs zipir", "MB/s", "RSS MiB"], out)


def file_table(rows):
    out = [[f"{r['category']}.{r['class']}", r["tool"], r["level"], r["lane"], num(r["mbs"], 1),
            num(r["wall_median_ns"] / 1e6, 2), num(r["rss_median_bytes"] / 1048576, 1),
            num(r["ratio"], 3) if r["op"] == "compress" else "", num(r["time_vs_zipir"], 2),
            num(r["size_vs_zipir"], 3)] for r in rows]
    return table(["file", "tool", "level", "lane", "MB/s", "ms", "RSS MiB", "ratio",
                  "time vs zipir", "size vs zipir"], out)


def rounds_text(facts):
    counts = sorted({r["samples"] for r in facts})
    return ", ".join(f"{c} rounds" for c in counts) + " after warmups"


def summary(run, facts):
    loads = sorted(float(r[k].split()[0]) for r in facts for k in ("load_before", "load_after"))
    commits = sorted({f"{r['commit']}{' (dirty)' if r['dirty'] == 'true' else ''}" for r in facts})
    lines = [f"# Bench summary: {run}", "",
             f"Matched Zebrac batches: every subject of a file and operation runs in the same interleaved "
             f"rounds ({rounds_text(facts)}, one pinned CPU). Commit {', '.join(commits)}. Host load "
             f"(1 min) {loads[0]:.1f} to {loads[-1]:.1f}. MB/s is uncompressed bytes per second (10^6). "
             f"'vs zipir' is the tool divided by zipir in the same batch and lane: time above 1.00 is "
             f"slower, size above 1.000 is larger. Streaming and full-buffer decoders are labeled, not ranked.",
             ""]
    lanes = []
    for fmt, op in sorted({(r["format"], r["op"]) for r in facts}):
        rows = [r for r in facts if r["format"] == fmt and r["op"] == op]
        # Sanity files measure process start-up more than the codec: averaged only when alone.
        classes = sorted({r["class"] for r in rows} - {"sanity"}, key=CLASS_ORDER.get) or ["sanity"]
        for cls in classes:
            lanes.append(f"## {fmt} {op}, {cls} files\n\n{lane_table([r for r in rows if r['class'] == cls])}")
            lines += [lanes[-1], ""]
        lines += [f"### {fmt} {op} per file", "", file_table(rows), ""]
    return "\n".join(lines), "\n\n".join(lanes)


def main():
    args = sys.argv[1:]
    check = "--check" in args
    args = [a for a in args if a != "--check"]
    if len(args) > 1 or any(a.startswith("-") for a in args):
        die(__doc__.strip().splitlines()[2])
    run = args[0] if args else "prime-lanes"
    facts, problems = load(run)
    for problem in problems:
        print(f"problem: {problem}", file=sys.stderr)
    if check or not facts:
        print(f"report check: {run}: {len(facts)} rows, {len(problems)} problems")
        return 1 if problems else 0
    out = REPORT / run
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "facts.tsv", "w") as f:
        f.write("\t".join(FACTS) + "\n")
        for r in facts:
            f.write("\t".join("" if r[k] is None else (f"{r[k]:.6g}" if isinstance(r[k], float) else str(r[k]))
                              for k in FACTS) + "\n")
    text, lanes = summary(run, facts)
    (out / "summary.md").write_text(text)
    print(lanes)
    print(f"\nreport: {out / 'facts.tsv'} ({len(facts)} rows)\nreport: {out / 'summary.md'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
