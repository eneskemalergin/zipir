#!/usr/bin/env python3
"""Replace zipir's rows in a benchmark run with rows timed later, keeping every other tool's rows as measured.

    python3 bench/splice.py BASE OUT NEW... [--control FILE]

BASE and NEW are run names under tools/.local/bench/. For every batch of BASE that a NEW run also has (same format,
operation, and file), OUT gets BASE's batch with the zipir rows and their Zebrac results taken from the last NEW run
that has it (so a later run of re-timed batches overrides an earlier one); every other batch of BASE is copied
unchanged. Peer rows are never re-timed or edited. OUT/splice.tsv records where each part came
from, and bench/report.py states it in the report: spliced zipir rows were not timed in the same rounds as the peers.

`--control FILE` copies a note (a TSV of key and value lines) into splice.tsv, for example a peer re-timed next to
the new zipir rows to show how much the machine's load moved between the runs.

Nothing is deleted. OUT must not exist yet.
"""
import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BENCH = ROOT / 'tools/.local/bench'


def read_batch(tsv):
    """(header lines, column line, rows as lists) of a batch TSV."""
    head, columns, rows = [], None, []
    for line in tsv.read_text().splitlines():
        if line.startswith('# '):
            head.append(line)
        elif columns is None:
            columns = line
        elif line:
            rows.append(line.split('\t'))
    return head, columns, rows


def meta_of(head):
    meta = {}
    for line in head:
        key, _, value = line[2:].partition('\t')
        meta.setdefault(key, value)
    return meta


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('base')
    ap.add_argument('out')
    ap.add_argument('new', nargs='+')
    ap.add_argument('--control')
    args = ap.parse_args()
    base, out = BENCH / args.base, BENCH / args.out
    news = [BENCH / n for n in args.new]
    if out.exists():
        sys.exit(f'{out} exists; choose a new name (nothing is deleted)')
    spliced, copied, new_meta = 0, 0, None
    for tsv in sorted(base.glob('*/*/*.tsv')):
        if tsv.name.endswith('.part.tsv'):
            continue
        rel = tsv.relative_to(base)
        target = out / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        head, columns, rows = read_batch(tsv)
        results = json.loads(tsv.with_suffix('.json').read_text())
        other = next((n / rel for n in reversed(news) if (n / rel).exists()), None)
        if other is None:
            target.write_text(tsv.read_text())
            target.with_suffix('.json').write_text(tsv.with_suffix('.json').read_text())
            copied += 1
            continue
        n_head, n_columns, n_rows = read_batch(other)
        n_results = json.loads(other.with_suffix('.json').read_text())
        meta, n_meta = meta_of(head), meta_of(n_head)
        new_meta = new_meta or n_meta
        # The timing CPU may differ (another core of the same processor); it is recorded, not required to match.
        for key in ('format', 'op', 'category', 'class', 'input', 'input_bytes', 'plain_bytes'):
            if meta.get(key) != n_meta.get(key):
                sys.exit(f'{rel}: {key} differs between runs ({meta.get(key)!r} and {n_meta.get(key)!r})')
        if columns != n_columns:
            sys.exit(f'{rel}: columns differ between runs')
        tool = f'zipir-{meta["format"]}'
        if len(n_rows) != len(n_results['results']) or len(rows) != len(results['results']):
            sys.exit(f'{rel}: rows and Zebrac results do not match')
        zipir_new = [(r, x) for r, x in zip(n_rows, n_results['results']) if r[0] == tool]
        peers = [(r, x) for r, x in zip(rows, results['results']) if r[0] != tool]
        old_levels = [r[1] for r in rows if r[0] == tool]
        if [r[1] for r, _ in zipir_new] != old_levels:
            sys.exit(f'{rel}: zipir levels differ between runs ({old_levels} and {[r[1] for r, _ in zipir_new]})')
        kept = [line for line in head if not line.startswith(('# key\t', '# commit\t', '# dirty\t'))]
        extra = [f'# key\tspliced from {args.base} and {other.relative_to(BENCH).parts[0]}',
                 f'# commit\t{n_meta.get("commit", "")}', f'# dirty\t{n_meta.get("dirty", "")}',
                 f'# zipir_from\t{other.relative_to(BENCH).parts[0]}', f'# peers_from\t{args.base}',
                 f'# peers_commit\t{meta.get("commit", "")}',
                 f'# zipir_load_before\t{n_meta.get("load_before", "")}',
                 f'# zipir_load_after\t{n_meta.get("load_after", "")}',
                 f'# zipir_cpu\t{n_meta.get("cpu", "")}']
        # Keys are read first-wins by bench/report.py, so the new commit goes first.
        target.write_text('\n'.join(extra + kept + [columns] + ['\t'.join(r) for r, _ in zipir_new + peers]) + '\n')
        results['results'] = [x for _, x in zipir_new] + [x for _, x in peers]
        target.with_suffix('.json').write_text(json.dumps(results))
        spliced += 1
    if spliced == 0:
        sys.exit(f'{" ".join(args.new)} share no batch with {args.base}')
    old_commit = meta_of(read_batch(next(base.glob('*/*/*.tsv')))[0]).get('commit', '')
    lines = [f'base\t{args.base}', f'new\t{" ".join(args.new)}', f'zipir_commit\t{new_meta.get("commit", "")}',
             f'peers_commit\t{old_commit}', f'spliced_batches\t{spliced}', f'copied_batches\t{copied}',
             f'zipir_cpu\t{new_meta.get("cpu", "")}', f'peers_cpu\t{meta_of(read_batch(next(base.glob("*/*/*.tsv")))[0]).get("cpu", "")}']
    if args.control:
        lines += [line for line in pathlib.Path(args.control).read_text().splitlines() if line.strip()]
    (out / 'splice.tsv').write_text('\n'.join(lines) + '\n')
    print(f'wrote {out.relative_to(ROOT)}: {spliced} batches with new zipir rows, {copied} copied unchanged')


if __name__ == '__main__':
    main()
