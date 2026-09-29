#!/usr/bin/env python3
"""Render the published benchmark report from a finished tools/bench.sh run.

usage: python3 bench/report.py [RUN] [--target linux-x86-avx2]

Reads tools/.local/report/RUN/facts.tsv (written by tools/report.py) and the batch files under
tools/.local/bench/RUN/ (for CPU cycles and instructions), and writes bench/TARGET/: README.md,
measurements.tsv, summary.tsv, and light and dark SVG figures. It measures nothing: timing,
qualification, and correctness checks belong to tools/ (see tools/README.md). Standard library only.
"""
import argparse
import csv
import datetime
import json
import math
import pathlib
import re
import subprocess
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parents[1]

# ---- what the report covers ----

FORMATS = ('gzip', 'zlib', 'deflate', 'bgzf')
FORMAT_NAME = {'gzip': 'gzip', 'zlib': 'zlib', 'deflate': 'raw DEFLATE', 'bgzf': 'BGZF'}
LANES = ('fast', 'balanced', 'dense')
LANE_LEVEL = {'fast': 1, 'balanced': 5, 'dense': 9}
CLASSES = ('small', 'medium')  # sanity files mostly measure process start-up
CATEGORY_NAME = {'sequencing': 'Sequencing', 'ms': 'Mass spectrometry', 'generalized': 'General'}
SIZE_TIE = 0.01  # "no larger than zipir's output": within +1%

# Tool families: one color and marker per tool, whatever container its adapter writes.
FAMILY = {
    'zipir-gzip': 'zipir', 'zipir-zlib': 'zipir', 'zipir-deflate': 'zipir', 'zipir-bgzf': 'zipir',
    'zlib-ng': 'zlib-ng', 'zlib-ng-zlib': 'zlib-ng', 'zlib-ng-deflate': 'zlib-ng',
    'igzip': 'igzip', 'std-gzip': 'zig-std', 'std-zlib': 'zig-std',
    'bgzip-libdeflate': 'bgzip-libdeflate', 'bgzip-zlib-ng': 'bgzip-zlib-ng',
    'libdeflate-gzip': 'libdeflate',
}
FAMILY_NAME = {
    'zipir': 'zipir', 'zlib-ng': 'zlib-ng', 'igzip': 'ISA-L igzip', 'zig-std': 'Zig std',
    'bgzip-libdeflate': 'bgzip + libdeflate', 'bgzip-zlib-ng': 'bgzip + zlib-ng',
    'libdeflate': 'libdeflate CLI (full buffer)',
}
FAMILY_ORDER = ('zipir', 'zlib-ng', 'igzip', 'zig-std', 'bgzip-libdeflate', 'bgzip-zlib-ng', 'libdeflate')
MARKER = {'zipir': 'circle', 'zlib-ng': 'square', 'igzip': 'triangle', 'zig-std': 'diamond',
          'bgzip-libdeflate': 'square', 'bgzip-zlib-ng': 'triangle', 'libdeflate': 'diamond'}

# zipir wears Zig's orange-yellow (#F7A41D). Light mode uses #E08E0B, the same hue one step darker, which passes
# every check of the dataviz palette validator; its 2.5:1 contrast is relieved by direct labels and tables.
# Dark mode uses #F7A41D itself: it passes separation and contrast and exceeds only the lightness band, which
# balances equal series; zipir is deliberately the emphasized one. Peers: zlib-ng blue, igzip aqua, bgzip +
# libdeflate violet, bgzip + zlib-ng magenta, all validated beside zipir all-pairs in each panel and adjacent in
# the full order. Zig std never competes and is a gray reference.
THEMES = {
    'light': {
        'surface': '#fcfcfb', 'ink': '#0b0b0b', 'ink2': '#52514e', 'muted': '#898781', 'grid': '#e1e0d9',
        'axis': '#c3c2b7', 'peer_zone': '#f2f1ed', 'zipir_zone': '#fdf2de',
        'zipir': '#e08e0b', 'zlib-ng': '#2a78d6', 'igzip': '#1baf7a', 'zig-std': '#898781',
        'bgzip-libdeflate': '#4a3aa7', 'bgzip-zlib-ng': '#e87ba4', 'libdeflate': '#4a3aa7',
    },
    'dark': {
        'surface': '#1a1a19', 'ink': '#ffffff', 'ink2': '#c3c2b7', 'muted': '#898781', 'grid': '#2c2c2a',
        'axis': '#383835', 'peer_zone': '#222221', 'zipir_zone': '#2b2416',
        'zipir': '#f7a41d', 'zlib-ng': '#3987e5', 'igzip': '#199e70', 'zig-std': '#898781',
        'bgzip-libdeflate': '#9085e9', 'bgzip-zlib-ng': '#d55181', 'libdeflate': '#9085e9',
    },
}
FONT = 'system-ui, -apple-system, &quot;Segoe UI&quot;, Helvetica, Arial, sans-serif'


# ---- data ----

def load(run):
    facts_path = ROOT / 'tools/.local/report' / run / 'facts.tsv'
    rows = list(csv.DictReader(open(facts_path), delimiter='\t'))
    counters = {}
    meta = {}
    for tsv in (ROOT / 'tools/.local/bench' / run).glob('*/*/*.tsv'):
        if tsv.name.endswith('.part.tsv'):
            continue
        head, subjects, header = {}, [], None
        for line in tsv.read_text().splitlines():
            if line.startswith('# '):
                k, _, v = line[2:].partition('\t')
                if k == 'cpu' and not v.isdigit():
                    head['cpu_model'] = v
                head.setdefault(k, v)
            elif header is None:
                header = line.split('\t')
            elif line:
                subjects.append(dict(zip(header, line.split('\t'))))
        results = json.loads(tsv.with_suffix('.json').read_text())['results']
        for s, r in zip(subjects, results):
            key = (head['format'], head['op'], head['category'], head['class'], s['tool'], s['level'])
            counters[key] = (r['cpu_cycles']['median'], r['instructions']['median'], r['wall_time']['min'],
                             r['wall_time']['max'], r['peak_rss']['max'])
        meta.setdefault('host', head.get('host'))
        meta.setdefault('kernel', head.get('kernel'))
        meta.setdefault('cpu_model', head.get('cpu_model'))
        meta.setdefault('commit', head.get('commit'))
        meta.setdefault('dirty', head.get('dirty'))
        loads = [float(head[k].split()[0]) for k in ('load_before', 'load_after') if k in head]
        meta.setdefault('loads', []).extend(loads)
    # A spliced run (bench/splice.py) carries zipir's compression rows from a later zipir-only run.
    splice = ROOT / 'tools/.local/bench' / run / 'splice.tsv'
    if splice.exists():
        meta['splice'] = dict(line.split('\t', 1) for line in splice.read_text().splitlines() if '\t' in line)
        meta['commit'] = meta['splice']['zipir_commit']
    for r in rows:
        for k in ('wall_median_ns', 'wall_q1_ns', 'wall_q3_ns', 'rss_median_bytes', 'plain_bytes', 'input_bytes',
                  'compressed_bytes', 'mbs', 'time_vs_zipir', 'rss_vs_zipir'):
            r[k] = float(r[k]) if r[k] else None
        for k in ('ratio', 'size_vs_zipir'):
            r[k] = float(r[k]) if r[k] else None
        r['family'] = FAMILY[r['tool']]
        r['spread_pct'] = 100 * (r['wall_q3_ns'] / r['wall_q1_ns'] - 1)
        c = counters.get((r['format'], r['op'], r['category'], r['class'], r['tool'], r['level']))
        r['cycles'], r['instructions'], r['wall_min_ns'], r['wall_max_ns'], r['rss_max_bytes'] = c or (None,) * 5
    return rows, meta


def gmean(values):
    values = [v for v in values if v]
    return math.exp(sum(map(math.log, values)) / len(values)) if values else None


def input_label(r, short=False):
    name = r['file']
    kind = {
        'DRR003897.fastq': 'FASTQ', 'SRR389222_sub1.fastq': 'FASTQ', 'chr21.bam': 'BAM',
        'hapmap_3.pop_stratified_chr21.vcf': 'VCF', 'PRIDE_Exp_Complete_Ac_22134.xml': 'PRIDE XML',
        '55merge_tandem.mzid': 'mzIdentML', 'cantrbry.tar': 'Canterbury tar', 'silesia.tar': 'Silesia tar',
    }
    stem = re.sub(r'\.(gz|zlib|deflate)$', '', name)
    label = kind.get(stem, stem)
    size = r['plain_bytes'] / 1e6
    return label if short else f'{label}, {size:.1f} MB'


def summary_rows(rows):
    """One row per path: the fastest peer, and for compression the fastest peer no larger than zipir."""
    out = []
    for op in ('decompress', 'compress'):
        for fmt in FORMATS:
            for lane in (LANES if op == 'compress' else (None,)):
                sel = [r for r in rows if r['format'] == fmt and r['op'] == op and r['class'] in CLASSES]
                zipir = [r for r in sel if r['family'] == 'zipir' and (lane is None or r['lane'] == lane)]
                if not zipir:
                    continue
                files = {(r['category'], r['class']) for r in zipir}
                peers = defaultdict(list)
                for r in sel:
                    if r['family'] == 'zipir' or (lane is not None and r['lane'] != lane):
                        continue
                    peers[(r['tool'], r['level'])].append(r)
                cands = []
                for (tool, level), items in peers.items():
                    if {(i['category'], i['class']) for i in items} != files:
                        continue
                    t = gmean([i['time_vs_zipir'] for i in items])
                    s = gmean([i['size_vs_zipir'] for i in items]) if op == 'compress' else 1.0
                    cands.append({'tool': tool, 'family': FAMILY[tool], 'level': level, 'time': t, 'size': s,
                                  'time_lo': min(i['time_vs_zipir'] for i in items),
                                  'time_hi': max(i['time_vs_zipir'] for i in items),
                                  'rss': gmean([i['rss_vs_zipir'] for i in items]), 'files': len(items)})
                fastest = min(cands, key=lambda c: c['time'])
                equal = [c for c in cands if c['size'] <= 1 + SIZE_TIE]
                equal = min(equal, key=lambda c: c['time']) if equal else None
                zipir_mbs = [z['mbs'] for z in zipir]
                out.append({'op': op, 'format': fmt, 'lane': lane, 'files': len(files), 'fastest': fastest,
                            'equal': equal, 'zipir_mbs_lo': min(zipir_mbs), 'zipir_mbs_hi': max(zipir_mbs),
                            'zipir_rss_mib': max(z['rss_median_bytes'] for z in zipir) / 1048576})
    return out


# ---- SVG helpers ----

def esc(text):
    return str(text).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def text_width(text, size):
    return 0.56 * size * len(text)


class Svg:
    def __init__(self, width, height, theme, title, desc):
        self.w, self.h, self.t = width, height, THEMES[theme]
        self.parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" width="{width}" '
                      f'height="{height}" role="img" font-family="{FONT}">',
                      f'<title>{esc(title)}</title><desc>{esc(desc)}</desc>',
                      f'<rect width="{width}" height="{height}" rx="12" fill="{self.t["surface"]}"/>']

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=13, color='ink', anchor='start', weight=400, extra=''):
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{self.t[color]}" text-anchor="{anchor}" '
                 f'font-weight="{weight}" {extra}>{esc(s)}</text>')

    def line(self, x1, y1, x2, y2, color='grid', width=1, extra=''):
        self.add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{self.t[color]}" '
                 f'stroke-width="{width}" {extra}/>')

    def rect(self, x, y, w, h, color, rx=0, extra=''):
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{max(w, 0):.1f}" height="{h:.1f}" rx="{rx}" '
                 f'fill="{self.t[color]}" {extra}/>')

    def marker(self, x, y, family, r=5.5, hollow=False, tip='', see_through=False):
        color = self.t[family]
        fill = 'none' if see_through else (self.t['surface'] if hollow else color)
        stroke = f'stroke="{color}" stroke-width="2.2"' if hollow else f'stroke="{self.t["surface"]}" stroke-width="2"'
        shape = MARKER[family]
        tip = f'<title>{esc(tip)}</title>' if tip else ''
        if shape == 'circle':
            self.add(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{fill}" {stroke}>{tip}</circle>')
        elif shape == 'square':
            s = r * 1.8
            self.add(f'<rect x="{x - s / 2:.1f}" y="{y - s / 2:.1f}" width="{s:.1f}" height="{s:.1f}" rx="1.5" '
                     f'fill="{fill}" {stroke}>{tip}</rect>')
        elif shape == 'triangle':
            s = r * 1.25
            self.add(f'<path d="M{x:.1f},{y - s * 1.1:.1f} L{x + s:.1f},{y + s * 0.8:.1f} L{x - s:.1f},{y + s * 0.8:.1f} Z" '
                     f'fill="{fill}" {stroke} stroke-linejoin="round">{tip}</path>')
        else:
            s = r * 1.3
            self.add(f'<path d="M{x:.1f},{y - s:.1f} L{x + s:.1f},{y:.1f} L{x:.1f},{y + s:.1f} L{x - s:.1f},{y:.1f} Z" '
                     f'fill="{fill}" {stroke} stroke-linejoin="round">{tip}</path>')

    def legend(self, x, y, families, extra_items=()):
        for fam in families:
            self.marker(x + 6, y - 4, fam)
            self.text(x + 18, y, FAMILY_NAME[fam], 12, 'ink2')
            x += 30 + text_width(FAMILY_NAME[fam], 12)
        for draw, label in extra_items:
            draw(x + 6, y - 4)
            self.text(x + 18, y, label, 12, 'ink2')
            x += 30 + text_width(label, 12)
        return x

    def save(self, path):
        self.add('</svg>')
        path.write_text('\n'.join(self.parts) + '\n')


def log_scale(lo, hi, x0, x1):
    a, b = math.log(lo), math.log(hi)
    return lambda v: x0 + (math.log(min(max(v, lo), hi)) - a) / (b - a) * (x1 - x0)


def speed_phrase(ratio, short=False):
    """ratio = peer time / zipir time."""
    if abs(ratio - 1) < 0.02:
        return 'same speed'
    if ratio < 1:
        return f'{1 / ratio:.2f}x faster' if short else f'{1 / ratio:.2f}x faster than zipir'
    return f'zipir {ratio:.2f}x faster' if short else f'zipir {ratio:.2f}x faster'


def size_phrase(size):
    delta = 100 * (size - 1)
    if abs(delta) < 0.5:
        return 'same size'
    return f'{delta:+.0f}% size' if abs(delta) >= 1.5 else f'{delta:+.1f}% size'


# ---- figure 1: summary ----

def figure_summary(summary, meta, theme, path):
    w = 1180
    left, plot_l, plot_r = 28, 236, 566
    col1, col2 = 600, 912
    row_h = 27
    rows = []
    for op in ('decompress', 'compress'):
        rows.append(('header', 'Decompression' if op == 'decompress' else 'Compression, by level'))
        for s in summary:
            if s['op'] == op:
                rows.append(('row', s))
    top = 124
    h = top + sum(34 if kind == 'header' else row_h for kind, _ in rows) + 108
    svg = Svg(w, h, theme, 'zipir against the fastest peer, by path',
              'For each format, operation, and level: the fastest single-threaded peer relative to zipir, and for '
              'compression the fastest peer whose output is no larger than zipir\'s.')
    svg.text(left, 38, 'zipir against the fastest peer on every path', 20, weight=650)
    svg.text(left, 62, 'Peer time divided by zipir time: geometric mean over the small and medium corpus files, '
             'whiskers across files. Left of 1 the peer is faster.', 13, 'ink2')
    rounds = ('matched interleaved rounds (zipir compression re-timed separately)' if meta.get('splice')
              else 'matched interleaved rounds')
    svg.text(left, 81, f'{meta["cpu"]} (Zen 2, AVX2), Linux, one thread per process, {rounds}. '
             f'zipir {meta["commit"][:7]}.', 13, 'ink2')
    x = log_scale(0.05, 5.0, plot_l, plot_r)
    y = top
    placed = []
    for kind, item in rows:
        if kind == 'header':
            placed.append((kind, item, y + 22))
            y += 34
        else:
            placed.append((kind, item, y + row_h / 2))
            y += row_h
    plot_top, plot_bottom = top, y
    svg.rect(plot_l, plot_top, x(1.0) - plot_l, plot_bottom - plot_top, 'peer_zone')
    svg.rect(x(1.0), plot_top, plot_r - x(1.0), plot_bottom - plot_top, 'zipir_zone')
    for tick in (0.05, 0.1, 0.25, 0.5, 1, 2, 4):
        svg.line(x(tick), plot_top, x(tick), plot_bottom, 'grid')
        svg.text(x(tick), plot_bottom + 18, f'{tick:g}', 11, 'muted', 'middle')
    svg.line(x(1.0), plot_top, x(1.0), plot_bottom, 'zipir', 2)
    svg.text(plot_l + 6, plot_top - 9, 'peer faster', 11, 'muted')
    svg.text(plot_r - 6, plot_top - 9, 'zipir faster', 11, 'muted', 'end')
    svg.text((plot_l + plot_r) / 2, plot_bottom + 36, 'peer time / zipir time, log scale', 12, 'ink2', 'middle')
    svg.text(col1, plot_top - 9, 'Fastest peer', 11, 'muted', weight=600)
    svg.text(col2, plot_top - 9, 'Fastest peer with output no larger', 11, 'muted', weight=600)
    for kind, item, cy in placed:
        if kind == 'header':
            svg.text(left, cy, item, 13, 'ink', weight=650)
            svg.line(left, cy + 7, w - 28, cy + 7, 'grid')
            continue
        s = item
        label = FORMAT_NAME[s['format']] + (f', level {LANE_LEVEL[s["lane"]]}' if s['lane'] else '')
        svg.text(left + 12, cy + 4, label, 13, 'ink2')
        f, e = s['fastest'], s['equal']
        same = e is not None and (e['tool'], e['level']) == (f['tool'], f['level'])
        svg.line(x(f['time_lo']), cy, x(f['time_hi']), cy, f['family'], 2, 'stroke-linecap="round" opacity="0.55"')
        if e and not same:
            svg.marker(x(e['time']), cy, e['family'], 5, hollow=True,
                       tip=f'{FAMILY_NAME[e["family"]]} {e["level"]}: {speed_phrase(e["time"])}, {size_phrase(e["size"])}')
        svg.marker(x(f['time']), cy, f['family'], tip=f'{FAMILY_NAME[f["family"]]}: {speed_phrase(f["time"])}')
        lvl = f' {f["level"]}' if f['level'] != '-' else ''
        first = f'{FAMILY_NAME[f["family"]]}{lvl}, {speed_phrase(f["time"], True)}'
        if s['op'] == 'compress':
            first += f', {size_phrase(f["size"])}'
        svg.text(col1, cy + 4, first, 12, 'ink')
        if s['op'] == 'compress':
            if e is None:
                second = 'none'
            elif same:
                second = 'same peer'
            else:
                second = f'{FAMILY_NAME[e["family"]]} {e["level"]}, {speed_phrase(e["time"], True)}'
            svg.text(col2, cy + 4, second, 12, 'ink2')
    ly = plot_bottom + 70
    zipir_key = (lambda px, py: svg.line(px + 6, py - 9, px + 6, py + 3, 'zipir', 2), 'zipir = 1.0')
    hollow_key = (lambda px, py: svg.marker(px, py, 'zig-std', 5, hollow=True), 'hollow: fastest peer with output no larger')
    svg.legend(left, ly, [f for f in FAMILY_ORDER if f != 'zipir'], [zipir_key, hollow_key])
    rss = max(s['zipir_rss_mib'] for s in summary)
    svg.text(left, ly + 24, f'zipir peaks at {rss:.1f} MiB of memory on every path. "No larger": output within 1% of zipir\'s. '
             'Levels are each tool\'s fast, balanced, and dense settings on its own scale; the full report has every value.', 12, 'muted')
    svg.save(path)


# ---- figure 2: compression trade-off ----

def figure_tradeoff(rows, fmt, theme, path):
    comp = [r for r in rows if r['format'] == fmt and r['op'] == 'compress' and r['class'] in CLASSES]
    inputs = []
    for cat in ('sequencing', 'ms', 'generalized'):
        for cls in ('medium', 'small'):
            if any(r['category'] == cat and r['class'] == cls for r in comp):
                inputs.append((cat, cls))
                break
    families = [f for f in FAMILY_ORDER if any(r['family'] == f for r in comp)]
    pw, ph, gap, left, top = 300, 290, 30, 66, 126
    w = left + len(inputs) * pw + (len(inputs) - 1) * gap + 30
    h = top + ph + 96
    svg = Svg(w, h, theme, f'{FORMAT_NAME[fmt]} compression: speed against ratio',
              'Each tool at its fast, balanced, and dense levels; up and to the right is better.')
    svg.text(28, 38, f'{FORMAT_NAME[fmt]} compression: speed against compression ratio', 20, weight=650)
    svg.text(28, 62, 'Each line is one tool at its fast, balanced, and dense levels (numbers are levels on the tool\'s own '
             'scale). Up and to the right is better.', 13, 'ink2')
    svg.legend(28, 88, families)
    for i, (cat, cls) in enumerate(inputs):
        sel = [r for r in comp if r['category'] == cat and r['class'] == cls]
        x0 = left + i * (pw + gap)
        mbs = [r['mbs'] for r in sel]
        ratios = [r['ratio'] for r in sel]
        # Quarter-decade bounds around the data.
        lo_x = 10 ** (math.floor(math.log10(min(mbs)) * 4) / 4)
        hi_x = 10 ** (math.ceil(math.log10(max(mbs)) * 4) / 4)
        span = max(ratios) - min(ratios)
        lo_y, hi_y = min(ratios) - 0.08 * span, max(ratios) + 0.12 * span
        X = log_scale(lo_x, hi_x, x0, x0 + pw)
        Y = lambda v: top + ph - (v - lo_y) / (hi_y - lo_y) * ph
        svg.text(x0, top - 14, f'{CATEGORY_NAME[cat]}: {input_label(sel[0])}', 13, 'ink', weight=600)
        for tick in nice_log_ticks(lo_x, hi_x):
            svg.line(X(tick), top, X(tick), top + ph, 'grid')
            svg.text(X(tick), top + ph + 17, f'{tick:g}', 11, 'muted', 'middle')
        yticks = nice_ticks(lo_y, hi_y, 5)
        step = yticks[1] - yticks[0] if len(yticks) > 1 else 1
        decimals = max(0, -math.floor(math.log10(step) + 1e-9)) + (1 if round(step / 10 ** math.floor(math.log10(step)), 6) == 2.5 else 0)
        for tick in yticks:
            svg.line(x0, Y(tick), x0 + pw, Y(tick), 'grid')
            svg.text(x0 - 6, Y(tick) + 4, f'{tick:.{decimals}f}', 11, 'muted', 'end')
        svg.line(x0, top + ph, x0 + pw, top + ph, 'axis')
        # zipir last, so its curve sits on top where curves cross.
        for fam in sorted(families, key=lambda f: f == 'zipir'):
            pts = sorted((r for r in sel if r['family'] == fam and r['level'] != '-'), key=lambda r: int(r['level']))
            if not pts:
                continue
            d = ' '.join(f'{"M" if j == 0 else "L"}{X(p["mbs"]):.1f},{Y(p["ratio"]):.1f}' for j, p in enumerate(pts))
            svg.add(f'<path d="{d}" fill="none" stroke="{svg.t[fam]}" stroke-width="2" stroke-linejoin="round" '
                    f'stroke-linecap="round" opacity="0.85"/>')
            for p in pts:
                svg.marker(X(p['mbs']), Y(p['ratio']), fam,
                           tip=f'{FAMILY_NAME[fam]} level {p["level"]}: {p["mbs"]:.1f} MB/s, ratio {p["ratio"]:.3f}')
                svg.text(X(p['mbs']) + 8, Y(p['ratio']) - 7, p['level'], 10, 'muted')
        svg.text(x0 + pw / 2, top + ph + 36, 'MB/s, log scale', 11, 'ink2', 'middle')
    svg.text(24, top + ph / 2, 'compression ratio', 11, 'ink2', 'middle',
             extra=f'transform="rotate(-90 24 {top + ph / 2})"')
    svg.text(28, h - 20, 'Ratio is plaintext bytes / compressed bytes. MB/s is plaintext MB (10^6 bytes) per second of '
             'median wall time. Each panel has its own scales.', 12, 'muted')
    svg.save(path)


def nice_ticks(lo, hi, count):
    step = 10 ** math.floor(math.log10((hi - lo) / count))
    for m in (1, 2, 2.5, 5, 10):
        if (hi - lo) / (step * m) <= count:
            step *= m
            break
    t = math.ceil(lo / step) * step
    out = []
    while t <= hi + 1e-9:
        out.append(round(t, 6))
        t += step
    return out


def nice_log_ticks(lo, hi):
    out = []
    for e in range(math.floor(math.log10(lo)), math.ceil(math.log10(hi)) + 1):
        for m in (1, 2, 5):
            v = m * 10 ** e
            if lo <= v <= hi:
                out.append(v)
    return out


# ---- figure 3: decompression throughput ----

def figure_decode(rows, theme, path):
    dec = [r for r in rows if r['op'] == 'decompress' and r['class'] == 'medium']
    pw, gap, left, top = 420, 44, 150, 110
    bar, bar_gap, group_gap = 11, 3, 16
    panels = []
    for fmt in FORMATS:
        sel = [r for r in dec if r['format'] == fmt]
        groups = []
        for cat in ('sequencing', 'ms', 'generalized'):
            g = sorted((r for r in sel if r['category'] == cat), key=lambda r: FAMILY_ORDER.index(r['family']))
            if g:
                groups.append((cat, g))
        panels.append((fmt, groups))
    panel_h = max(sum(len(g) * (bar + bar_gap) + group_gap for _, g in groups) for _, groups in panels) + 30
    w = left + 2 * pw + gap + 40
    h = top + 2 * panel_h + 60
    maxv = max(r['mbs'] for r in dec) * 1.08
    families = [f for f in FAMILY_ORDER if any(r['family'] == f for r in dec)]
    svg = Svg(w, h, theme, 'Decompression throughput', 'MB/s of decoded output on the medium corpus files, per format.')
    svg.text(28, 38, 'Decompression throughput on the medium files', 20, weight=650)
    svg.text(28, 62, 'MB/s of decoded output, higher is better. Every decoder here streams, and all read the same file.',
             13, 'ink2')
    svg.legend(28, 88, families)
    for i, (fmt, groups) in enumerate(panels):
        col, row = i % 2, i // 2
        x0 = left + col * (pw + gap)
        y0 = top + row * panel_h
        X = lambda v: x0 + v / maxv * (pw - 60)
        svg.text(x0 - 120, y0 + 12, FORMAT_NAME[fmt], 14, 'ink', weight=650)
        y = y0 + 22
        for tick in nice_ticks(0, maxv, 5):
            svg.line(X(tick), y0 + 18, X(tick), y0 + panel_h - 20, 'grid')
            if row == 1:
                svg.text(X(tick), y0 + panel_h - 4, f'{tick:g}', 11, 'muted', 'middle')
        for cat, g in groups:
            svg.text(x0 - 10, y + (len(g) * (bar + bar_gap)) / 2 + 4, input_label(g[0], short=True), 12, 'ink2', 'end')
            best = max(r['mbs'] for r in g)
            for r in g:
                wv = X(r['mbs']) - x0
                svg.add(f'<path d="M{x0:.1f},{y:.1f} h{wv - 4:.1f} a4,4 0 0 1 4,4 v{bar - 8:.1f} a4,4 0 0 1 -4,4 '
                        f'h{-(wv - 4):.1f} Z" fill="{svg.t[r["family"]]}"><title>{esc(FAMILY_NAME[r["family"]])}: '
                        f'{r["mbs"]:.0f} MB/s</title></path>')
                if r['family'] == 'zipir' or r['mbs'] == best:
                    svg.text(X(r['mbs']) + 5, y + bar - 2, f'{r["mbs"]:.0f}', 10.5, 'ink2')
                y += bar + bar_gap
            y += group_gap
        svg.line(x0, y0 + 18, x0, y - group_gap + 2, 'axis')
    svg.text(left + pw + gap / 2, h - 22, 'MB/s. Values are shown for zipir and for the fastest tool on each file; '
             'the report tables list every value.', 12, 'muted', 'middle')
    svg.save(path)


# ---- figure 4: memory ----

def figure_memory(rows, theme, path):
    sel = [r for r in rows if r['class'] in CLASSES]
    fams = [f for f in FAMILY_ORDER if any(r['family'] == f for r in sel)]
    left, top, pw, row_h = 190, 110, 560, 34
    w, h = left + pw + 190, top + len(fams) * row_h + 84
    X = lambda v: left + v / 6.0 * pw
    svg = Svg(w, h, theme, 'Peak memory by tool', 'Peak resident set size of the whole process, small and medium files.')
    svg.text(28, 38, 'Peak memory of the whole process', 20, weight=650)
    svg.text(28, 62, 'Median peak RSS per run; the line spans every file and level. Filled: decompression. Hollow: '
             'compression. Lower is better.', 13, 'ink2')
    for tick in range(0, 7):
        svg.line(X(tick), top - 6, X(tick), top + len(fams) * row_h, 'grid')
        svg.text(X(tick), top + len(fams) * row_h + 18, f'{tick}', 11, 'muted', 'middle')
    svg.text(left + pw / 2, top + len(fams) * row_h + 38, 'MiB', 12, 'ink2', 'middle')
    for i, fam in enumerate(fams):
        cy = top + i * row_h + row_h / 2
        svg.text(left - 12, cy + 4, FAMILY_NAME[fam], 13, 'ink2', 'end')
        items = [r for r in sel if r['family'] == fam]
        vals = [r['rss_median_bytes'] / 1048576 for r in items]
        svg.line(X(min(vals)), cy, X(max(vals)), cy, fam, 2, 'stroke-linecap="round" opacity="0.5"')
        dec = [r['rss_median_bytes'] / 1048576 for r in items if r['op'] == 'decompress']
        com = [r['rss_median_bytes'] / 1048576 for r in items if r['op'] == 'compress']
        if com:
            svg.marker(X(statistics_median(com)), cy, fam, hollow=True, tip=f'compression median {statistics_median(com):.2f} MiB')
        if dec:
            svg.marker(X(statistics_median(dec)), cy, fam, tip=f'decompression median {statistics_median(dec):.2f} MiB')
        span = f'{min(vals):.2f} to {max(vals):.2f}' if max(vals) < 1 else f'{min(vals):.1f} to {max(vals):.1f}'
        svg.text(left + pw + 14, cy + 4, f'{span} MiB', 12, 'ink2')
    svg.text(28, h - 20, 'Whole-process RSS includes each program\'s runtime and libc, not only codec state. zipir and the '
             'Zig std adapter are static Zig programs; the others load libc.', 12, 'muted')
    svg.save(path)


def figure_memory_summary(rows, meta, theme, path):
    """Each tool's peak memory on every format and operation, in the summary figure's layout, for the main README."""
    sel = [r for r in rows if r['class'] in CLASSES]
    w = 1180
    left, plot_l, plot_r, col1 = 28, 236, 566, 600
    row_h = 27
    groups = []
    for op in ('decompress', 'compress'):
        groups.append(('header', 'Decompression' if op == 'decompress' else 'Compression, every level'))
        for fmt in FORMATS:
            items = [r for r in sel if r['op'] == op and r['format'] == fmt]
            if items:
                groups.append(('row', (fmt, op, items)))
    top = 124
    h = top + sum(34 if kind == 'header' else row_h for kind, _ in groups) + 124
    svg = Svg(w, h, theme, 'Peak memory on every path',
              'Median peak resident memory of the whole process for each tool, format, and operation.')
    svg.text(left, 38, 'Peak memory on every path', 20, weight=650)
    svg.text(left, 62, 'Median peak resident memory of the whole process over the small and medium corpus files, whiskers '
             'across files and levels. Lower is better.', 13, 'ink2')
    svg.text(left, 81, f'{meta["cpu"]} (Zen 2, AVX2), Linux, one thread per process, the runs of the summary figure. '
             f'zipir {meta["commit"][:7]}.', 13, 'ink2')
    top_mib = 5.0
    X = lambda v: plot_l + min(v, top_mib) / top_mib * (plot_r - plot_l)
    placed, y = [], top
    for kind, item in groups:
        if kind == 'header':
            placed.append((kind, item, y + 22))
            y += 34
        else:
            placed.append((kind, item, y + row_h / 2))
            y += row_h
    plot_top, plot_bottom = top, y
    for tick in range(0, 6):
        svg.line(X(tick), plot_top, X(tick), plot_bottom, 'grid')
        svg.text(X(tick), plot_bottom + 18, f'{tick}', 11, 'muted', 'middle')
    svg.text((plot_l + plot_r) / 2, plot_bottom + 36, 'peak memory, MiB', 12, 'ink2', 'middle')
    svg.text(plot_l + 6, plot_top - 9, 'less memory', 11, 'muted')
    svg.text(col1, plot_top - 9, 'zipir against the peers', 11, 'muted', weight=600)
    families_seen = []
    for kind, item, cy in placed:
        if kind == 'header':
            svg.text(left, cy, item, 13, 'ink', weight=650)
            svg.line(left, cy + 7, w - 28, cy + 7, 'grid')
            continue
        fmt, op, items = item
        svg.text(left + 12, cy + 4, FORMAT_NAME[fmt], 13, 'ink2')
        by_family = {}
        for r in items:
            by_family.setdefault(r['family'], []).append(r['rss_median_bytes'] / 1048576)
        # Zig std sits on zipir's value, so it is drawn last and hollow: both stay visible.
        order = [f for f in FAMILY_ORDER if f in by_family and f not in ('zipir', 'zig-std')] + ['zipir']
        order += ['zig-std'] if 'zig-std' in by_family else []
        # Peer markers closer than a marker's width are nudged apart vertically so each stays visible.
        peer_x, nudge = [], 0
        for fam in order:
            vals = by_family[fam]
            if fam not in families_seen:
                families_seen.append(fam)
            mx, my = X(statistics_median(vals)), cy
            if fam not in ('zipir', 'zig-std'):
                if any(abs(mx - px) < 11 for px in peer_x):
                    nudge += 1
                    my = cy + (5 if nudge % 2 else -5)
                peer_x.append(mx)
            svg.line(X(min(vals)), cy, X(max(vals)), cy, fam, 2, 'stroke-linecap="round" opacity="0.55"')
            svg.marker(mx, my, fam, r=7.5 if fam == 'zig-std' else 5.5, hollow=fam == 'zig-std', see_through=fam == 'zig-std',
                       tip=f'{FAMILY_NAME[fam]}: median {statistics_median(vals):.2f} MiB, {min(vals):.2f} to {max(vals):.2f}')
        zipir = statistics_median(by_family['zipir'])
        c_peers = [statistics_median(v) for f, v in by_family.items() if f not in ('zipir', 'zig-std')]
        text = f'zipir {zipir:.2f} MiB'
        if c_peers:
            lo, hi = min(c_peers), max(c_peers)
            noun = 'C peers' if len(c_peers) > 1 else 'C peer'
            mib = f'{lo:.1f} MiB' if f'{lo:.1f}' == f'{hi:.1f}' else f'{lo:.1f} to {hi:.1f} MiB'
            more = f'{lo / zipir:.1f}x' if f'{lo / zipir:.1f}' == f'{hi / zipir:.1f}' else f'{lo / zipir:.1f}x to {hi / zipir:.1f}x'
            text += f'; {noun} {mib}, {more} more'
        if 'zig-std' in by_family:
            text += f'; Zig std {statistics_median(by_family["zig-std"]):.2f} MiB'
        svg.text(col1, cy + 4, text, 12, 'ink')
    ly = plot_bottom + 70
    zig_key = (lambda px, py: svg.marker(px, py, 'zig-std', 6, hollow=True, see_through=True), FAMILY_NAME['zig-std'] + ' (outline)')
    svg.legend(left, ly, [f for f in FAMILY_ORDER if f in families_seen and f != 'zig-std'],
               [zig_key] if 'zig-std' in families_seen else [])
    svg.text(left, ly + 24, 'Whole-process peak: zipir and the Zig std adapter are static Zig programs and the C tools load libc, '
             'so part of the gap is the process, not the codec.', 12, 'muted')
    svg.text(left, ly + 42, 'zipir keeps each stream in one fixed workspace, so its peak does not grow with the input: 0.6 MiB on '
             'small and medium files alike.', 12, 'muted')
    svg.save(path)


PRESET_NAME = {'1': 'fast', '5': 'even', '9': 'dense'}
# Per format: the panels of the frontier figure, the files the equivalents average over (the preset targets' files),
# the peer families of the equivalents table, and the figure's subtitle.
FRONTIER = {
    'gzip': {
        'panels': (('sequencing', 'medium'), ('ms', 'medium'), ('generalized', 'small')),
        'average': (('sequencing', 'medium'), ('ms', 'medium'), ('generalized', 'small')),
        'families': ('zlib-ng', 'igzip', 'libdeflate'),
        'subtitle': 'zlib-ng 1 to 9, ISA-L igzip 0 to 3, and libdeflate\'s CLI 1 to 12 (dashed: it reads the whole file '
                    'into memory, a quality reference). Up and to the right is better.',
    },
    'bgzf': {
        'panels': (('sequencing', 'medium'), ('sequencing', 'small'), ('ms', 'medium'), ('generalized', 'small')),
        'average': (('sequencing', 'medium'), ('sequencing', 'small'), ('ms', 'medium'), ('ms', 'small'),
                    ('generalized', 'small')),
        'families': ('bgzip-libdeflate', 'bgzip-zlib-ng'),
        'subtitle': 'bgzip with libdeflate and with zlib-ng at every level (bgzip -l 1 to 9; with libdeflate, htslib maps them '
                    'onto libdeflate 1 to 12). Up and to the right is better.',
    },
}


def load_frontier(runs):
    """Peer rows of runs that timed every level (zipir's rows there are older and are left out)."""
    rows = [r for run in runs for r in csv.DictReader(open(ROOT / 'tools/.local/report' / run / 'facts.tsv'), delimiter='\t')
            if r['op'] == 'compress' and not r['tool'].startswith('zipir')]
    for r in rows:
        r['mbs'], r['ratio'] = float(r['mbs']), float(r['ratio'])
        r['family'] = FAMILY[r['tool']]
    return rows


def figure_frontier(rows, peers, fmt, theme, path):
    """Every peer level of `fmt` (from the frontier runs) against zipir's three presets (from the report run)."""
    spec = FRONTIER[fmt]
    peers = [r for r in peers if r['format'] == fmt]
    zipir = [r for r in rows if r['format'] == fmt and r['op'] == 'compress' and r['family'] == 'zipir'
             and r['level'] != '-']
    families = [f for f in FAMILY_ORDER if f == 'zipir' or any(r['family'] == f for r in peers)]
    panels = spec['panels']
    pw, ph, gap, left, top = 300, 300, 30, 66, 126
    w = left + len(panels) * pw + (len(panels) - 1) * gap + 30
    h = top + ph + 112
    title = f'{FORMAT_NAME[fmt]} compression: zipir presets against every peer level'
    svg = Svg(w, h, theme, title, spec['subtitle'])
    svg.text(28, 38, title, 20, weight=650)
    svg.text(28, 62, spec['subtitle'], 13, 'ink2')
    svg.legend(28, 88, families)
    for i, (cat, cls) in enumerate(panels):
        sel_peers = [r for r in peers if r['category'] == cat and r['class'] == cls and r['level'] != '-'
                     and (r['level'] != '0' or r['family'] == 'igzip')]
        sel_zipir = [r for r in zipir if r['category'] == cat and r['class'] == cls]
        sel = sel_peers + sel_zipir
        x0 = left + i * (pw + gap)
        mbs = [r['mbs'] for r in sel]
        ratios = [r['ratio'] for r in sel]
        lo_x = 10 ** (math.floor(math.log10(min(mbs)) * 4) / 4)
        hi_x = 10 ** (math.ceil(math.log10(max(mbs)) * 4) / 4)
        span = max(ratios) - min(ratios)
        lo_y, hi_y = min(ratios) - 0.08 * span, max(ratios) + 0.12 * span
        X = log_scale(lo_x, hi_x, x0, x0 + pw)
        Y = lambda v: top + ph - (v - lo_y) / (hi_y - lo_y) * ph
        svg.text(x0, top - 14, f'{CATEGORY_NAME[cat]}: {input_label(sel_zipir[0] if sel_zipir else sel[0])}', 13, 'ink',
                 weight=600)
        for tick in nice_log_ticks(lo_x, hi_x):
            svg.line(X(tick), top, X(tick), top + ph, 'grid')
            svg.text(X(tick), top + ph + 17, f'{tick:g}', 11, 'muted', 'middle')
        yticks = nice_ticks(lo_y, hi_y, 5)
        step = yticks[1] - yticks[0] if len(yticks) > 1 else 1
        decimals = max(0, -math.floor(math.log10(step) + 1e-9)) + (1 if round(step / 10 ** math.floor(math.log10(step)), 6) == 2.5 else 0)
        for tick in yticks:
            svg.line(x0, Y(tick), x0 + pw, Y(tick), 'grid')
            svg.text(x0 - 6, Y(tick) + 4, f'{tick:.{decimals}f}', 11, 'muted', 'end')
        svg.line(x0, top + ph, x0 + pw, top + ph, 'axis')
        for fam in sorted(families, key=lambda f: f == 'zipir'):
            pts = sorted((r for r in sel if r['family'] == fam), key=lambda r: int(r['level']))
            if not pts:
                continue
            d = ' '.join(f'{"M" if j == 0 else "L"}{X(p["mbs"]):.1f},{Y(p["ratio"]):.1f}' for j, p in enumerate(pts))
            dash = ' stroke-dasharray="4 4"' if fam == 'libdeflate' else ''
            svg.add(f'<path d="{d}" fill="none" stroke="{svg.t[fam]}" stroke-width="2"{dash} stroke-linejoin="round" '
                    f'stroke-linecap="round" opacity="0.85"/>')
            for p in pts:
                label = PRESET_NAME.get(p['level'], p['level']) if fam == 'zipir' else p['level']
                svg.marker(X(p['mbs']), Y(p['ratio']), fam,
                           tip=f'{FAMILY_NAME[fam]} {label}: {p["mbs"]:.1f} MB/s, ratio {p["ratio"]:.3f}')
                svg.text(X(p['mbs']) + 8, Y(p['ratio']) - 7, label, 10, 'ink' if fam == 'zipir' else 'muted',
                         weight=600 if fam == 'zipir' else 400)
        svg.text(x0 + pw / 2, top + ph + 36, 'MB/s, log scale', 11, 'ink2', 'middle')
    svg.text(24, top + ph / 2, 'compression ratio', 11, 'ink2', 'middle',
             extra=f'transform="rotate(-90 24 {top + ph / 2})"')
    svg.text(28, h - 36, 'Ratio is plaintext bytes / compressed bytes. MB/s is plaintext MB (10^6 bytes) per second of '
             'median wall time. Each panel has its own scales.', 12, 'muted')
    svg.text(28, h - 18, 'Peers come from a run of every level; zipir from the report run. Level 0 (stored) is left out, '
             'except igzip 0, which compresses.', 12, 'muted')
    svg.save(path)


def geo_points(sel, inputs):
    """(MB/s, ratio) geometric means over `inputs`, per (family, level), where all of them are present."""
    by = defaultdict(dict)
    for r in sel:
        if (r['category'], r['class']) in inputs:
            by[(r['family'], r['level'])][(r['category'], r['class'])] = (r['mbs'], r['ratio'])
    out = {}
    for k, v in by.items():
        if len(v) == len(inputs):
            out[k] = (math.exp(sum(math.log(a) for a, _ in v.values()) / len(v)),
                      math.exp(sum(math.log(b) for _, b in v.values()) / len(v)))
    return out


def equivalents_table(rows, peers, fmt):
    """For each zipir preset: the peer levels that bracket its ratio, with their speeds."""
    spec = FRONTIER[fmt]
    zip_pts = geo_points([r for r in rows if r['format'] == fmt and r['op'] == 'compress' and r['family'] == 'zipir'],
                         spec['average'])
    peer_pts = geo_points([r for r in peers if r['format'] == fmt and (r['level'] != '0' or r['family'] == 'igzip')],
                          spec['average'])
    out = []
    for level in ('1', '5', '9'):
        if ('zipir', level) not in zip_pts:
            continue
        zm, zr = zip_pts[('zipir', level)]
        cells = [PRESET_NAME[level], f'{zm:.1f}', f'{zr:.3f}']
        for fam in spec['families']:
            pts = sorted(((int(lv), m, r) for (f, lv), (m, r) in peer_pts.items() if f == fam), key=lambda t: t[2])
            below = [p for p in pts if p[2] <= zr]
            above = [p for p in pts if p[2] > zr]
            parts = []
            if below:
                lv, m, r = max(below, key=lambda t: t[2])
                parts.append(f'{lv}: {m:.0f} MB/s, {r:.3f}')
            if above:
                lv, m, r = min(above, key=lambda t: t[2])
                parts.append(f'{lv}: {m:.0f} MB/s, {r:.3f}')
            cells.append('<br>'.join(parts) if parts else '')
        out.append(cells)
    return md_table(['zipir preset', 'MB/s', 'Ratio'] + [f'{FAMILY_NAME[f]} levels around its ratio' for f in spec['families']],
                    out, ['---', '---:', '---:'] + ['---'] * len(spec['families']))


def statistics_median(values):
    v = sorted(values)
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2


# ---- tables and README ----

def md_table(header, rows, align=None):
    align = align or ['---'] * len(header)
    out = ['| ' + ' | '.join(header) + ' |', '| ' + ' | '.join(align) + ' |']
    out += ['| ' + ' | '.join(str(c) for c in row) + ' |' for row in rows]
    return '\n'.join(out)


def picture(name, alt):
    return (f'<p align="center">\n  <picture>\n'
            f'    <source media="(prefers-color-scheme: dark)" srcset="figures/{name}-dark.svg">\n'
            f'    <source media="(prefers-color-scheme: light)" srcset="figures/{name}-light.svg">\n'
            f'    <img src="figures/{name}-light.svg" alt="{alt}" width="100%">\n  </picture>\n</p>')


def fmt_ratio(v):
    return f'{v:.2f}x' if v is not None else ''


def write_readme(target, rows, summary, meta, out):
    L = []
    L.append(f'# zipir benchmark: {target}')
    L.append('')
    L.append(f'zipir `{meta["commit"][:12]}` ({"clean tree" if meta["dirty"] == "false" else "uncommitted changes"}), '
             f'measured on {meta["date"]}. One host: {meta["cpu"]}, {meta["kernel"]}.')
    L.append('')
    L.append('This report shows where zipir stands against the fastest single-threaded tools on the same machine, on '
             'every format zipir writes and reads. Compression is a trade-off between speed and output size, so '
             'compression results always show both; decompression output is identical across tools, so speed and '
             'memory are the whole story there.')
    L.append('')
    L.append('## Summary')
    L.append('')
    L.append(picture('summary', 'zipir against the fastest peer on every path'))
    L.append('')
    L.append('Each row compares zipir with every peer on the same path and names the fastest one; its marker sits left '
             'of 1.0 when the peer is faster. For compression, the fastest peer is often fast because it writes larger '
             'output, so a hollow marker shows the fastest peer whose output is no larger than zipir\'s (within 1%). '
             '"Level 1" compares each tool\'s fast level, "5" balanced, and "9" dense, on each tool\'s own scale '
             '([Levels](#levels)).')
    L.append('')
    tab = []
    for s in summary:
        f, e = s['fastest'], s['equal']
        path = f"{FORMAT_NAME[s['format']]} {s['op']}"
        lvl = str(LANE_LEVEL[s['lane']]) if s['lane'] else ''
        fl = f'{FAMILY_NAME[f["family"]]}' + (f' {f["level"]}' if f['level'] != '-' else '')
        row = [path, lvl, fl, f'{f["time"]:.2f} ({f["time_lo"]:.2f} to {f["time_hi"]:.2f})',
               size_phrase(f['size']) if s['op'] == 'compress' else '']
        if s['op'] == 'compress':
            row.append(f'{FAMILY_NAME[e["family"]]} {e["level"]}: {e["time"]:.2f}' if e else 'none')
        else:
            row.append('')
        row.append(f'{s["zipir_mbs_lo"]:.0f} to {s["zipir_mbs_hi"]:.0f}')
        tab.append(row)
    L.append(md_table(['Path', 'Level', 'Fastest peer', 'Peer time / zipir (range)', 'Its output',
                       'Fastest peer no larger than zipir', 'zipir MB/s'], tab,
                      ['---', '---:', '---', '---:', '---:', '---', '---:']))
    L.append('')
    L.append('### Reading the summary')
    L.append('')
    for line in reading_lines(summary, rows):
        L.append(f'- {line}')
    L.append('')
    L.append('## Compression: speed against ratio')
    L.append('')
    L.append('A single level says little about a compressor: a faster tool can simply be writing more bytes. These '
             'figures place every tool\'s fast, balanced, and dense levels on speed and compression ratio together. '
             'zlib and raw DEFLATE use the same engine as gzip in every tool here, so their curves follow gzip\'s; their '
             'figures and tables are in the folded sections below. zlib and raw DEFLATE have no ISA-L or Zig std '
             'compressor in this run.')
    L.append('')
    L.append(picture('tradeoff-gzip', 'gzip compression speed against compression ratio'))
    L.append('')
    L.append(picture('tradeoff-bgzf', 'BGZF compression speed against compression ratio'))
    L.append('')
    L.append('Each cell: MB/s, compression ratio. Peer cells add their time relative to zipir at the same level '
             '(below 1x is faster) and their output size relative to zipir\'s (+ is larger).')
    L.append('')
    for fmt in FORMATS:
        folded = fmt in ('zlib', 'deflate')
        if folded:
            L.append(f'<details><summary><b>{FORMAT_NAME[fmt]} compression</b> (same engines as gzip)</summary>')
        else:
            L.append(f'### {FORMAT_NAME[fmt]} compression')
        L.append('')
        if folded:
            L.append(picture(f'tradeoff-{fmt}', f'{FORMAT_NAME[fmt]} compression speed against compression ratio'))
            L.append('')
        L.append(compression_table(rows, fmt))
        L.append('')
        if folded:
            L.append('</details>')
            L.append('')
    L.append('## Decompression')
    L.append('')
    L.append(picture('decode', 'Decompression throughput on the medium files'))
    L.append('')
    L.append('Each cell: MB/s of decoded output; peer cells add their time relative to zipir (below 1x is faster).')
    L.append('')
    for fmt in FORMATS:
        L.append(f'### {FORMAT_NAME[fmt]} decompression')
        L.append('')
        L.append(decode_table(rows, fmt))
        L.append('')
    if meta.get('frontier'):
        L.append('## Presets against every peer level')
        L.append('')
        L.append('For each zipir preset, the levels of each peer whose ratios bracket it (the level just below and just '
                 'above), with their speed; geometric means over the files the presets are designed and judged on. Peer '
                 'levels come from runs of every level of each peer on these files (' +
                 ', '.join(f'`{r}`' for r in meta['frontier_runs']) + '); zipir comes from this report\'s run.')
        L.append('')
        for fmt in FRONTIER:
            if not any(r['format'] == fmt for r in meta['frontier']):
                continue
            L.append(f'### {FORMAT_NAME[fmt]}')
            L.append('')
            L.append(picture(f'frontier-{fmt}', f'{FORMAT_NAME[fmt]} compression: zipir presets against every peer level'))
            L.append('')
            L.append(equivalents_table(rows, meta['frontier'], fmt))
            L.append('')
        L.append('On gzip, libdeflate\'s CLI reads the whole file into memory (77 to 83 MiB here), so it shows what ratio '
                 'is reachable, not a streaming rival. On BGZF, `bgzip` compresses one 64 KiB block at a time with either '
                 'library, so both are streaming rivals there.')
        L.append('')
    L.append('## Memory')
    L.append('')
    L.append(picture('memory', 'Peak memory of the whole process by tool'))
    L.append('')
    L.append(memory_table(rows))
    L.append('')
    L.append('## zipir efficiency')
    L.append('')
    L.append('CPU cycles and instructions per plaintext byte for zipir on the medium files, from the same runs '
             '(user-space counters, median of 25 rounds). IPC is instructions per cycle.')
    L.append('')
    L.append(efficiency_table(rows))
    L.append('')
    L.append('## Terms')
    L.append('')
    L.extend(TERMS)
    L.append('')
    L.append('### Levels')
    L.append('')
    L.append(md_table(['Tool', 'fast', 'balanced', 'dense', 'Scale'], [
        ['zipir', '1', '5', '9', '1, 5, 9 (the only levels)'],
        ['zlib-ng', '1', '5', '9', '0 to 9'],
        ['ISA-L igzip', '0', '1', '2', '0 to 3; level 3 was not on its own speed-size frontier'],
        ['Zig std', '1', '5', '9', '1 to 9'],
        ['bgzip + libdeflate', '1', '5', '9', 'bgzip -l 0 to 9; htslib maps 1, 5, 9 to libdeflate 1, 6, 12'],
        ['bgzip + zlib-ng', '1', '5', '9', 'bgzip -l 0 to 9'],
    ]))
    L.append('')
    L.append('Peer levels were chosen from peer-only measurements, never from a zipir result.')
    L.append('')
    L.append('## Inputs')
    L.append('')
    L.append(inputs_table(rows))
    L.append('')
    L.append('The gzip, zlib, and raw DEFLATE rows of a category compress the same plaintext; every decoder of a format '
             'reads the same file. The sequencing BGZF inputs are real BGZF files (a VCF and a BAM), so their plaintext '
             'differs from the FASTQ of the other formats. Sanity-class files (under 120 KB) are measured but left out '
             'of the summary, since process start-up dominates them.')
    L.append('')
    L.append('## Method')
    L.append('')
    L.extend(METHOD)
    if meta.get('splice'):
        sp = meta['splice']
        runs = ', '.join(f'`{n}`' for n in sp['new'].split())
        L.append(f'- **zipir compression re-timed alone.** zipir\'s compression rows come from zipir-only runs '
                 f'({runs}, zipir `{sp["zipir_commit"][:12]}`, CPU {sp.get("zipir_cpu", "?")}; batches disturbed by other jobs '
                 f're-timed in the later runs); every peer row and zipir\'s decompression rows '
                 f'come from `{sp["base"]}` (zipir `{sp["peers_commit"][:12]}`, whose decoder is unchanged since; CPU '
                 f'{sp.get("peers_cpu", "?")}). '
                 f'So zipir\'s compression was not timed in the same rounds as the peers: load that differed between '
                 f'the two runs shifts zipir against every peer. {sp.get("control_note", "")}'.rstrip())
    L.extend(noise_lines(rows))
    L.append('')
    L.append('## Tools and versions')
    L.append('')
    L.extend(TOOLS_TEXT)
    L.append('')
    L.append('## Run conditions')
    L.append('')
    loads = meta['loads']
    L.append(f'- Host: {meta["cpu"]}, 32 logical CPUs, {meta["kernel"]}, CPU governor `{meta["governor"]}`. '
             f'CPU flags include AVX2, BMI2, and PCLMULQDQ; there is no AVX-512 or VPCLMULQDQ.')
    L.append('- Every batch ran pinned to CPU 4 (`taskset -c 4`). The machine was in normal use: the 1-minute load '
             f'average around the batches ranged from {min(loads):.1f} to {max(loads):.1f}. Matched rounds keep '
             'that load from favoring one tool (see [Method](#method)).')
    L.append(f'- Zebrac 0.6.2, Zig 0.16.0, GCC {meta["gcc"]}. Files were in the page cache.')
    L.append('')
    L.append('## Limits')
    L.append('')
    L.extend(LIMITS)
    L.append('')
    L.append('## Files')
    L.append('')
    L.append('- [`measurements.tsv`](measurements.tsv): every timed row (file, tool, level, time quartiles, peak RSS, '
             'sizes, ratios against zipir, CPU cycles and instructions).')
    L.append('- [`summary.tsv`](summary.tsv): the values behind the summary figure and table.')
    L.append(f'- Generated by [`bench/report.py`](../report.py) from the `{meta["run"]}` run of '
             '[`tools/bench.sh`](../../tools/README.md).')
    L.append('')
    (out / 'README.md').write_text('\n'.join(L))


TERMS = [
    '- **Peer time / zipir time**: median wall time of the peer divided by zipir\'s median in the same batch and '
    'level lane. Below 1.00 the peer is faster. Summary values are geometric means over files.',
    '- **Output size**: the peer\'s compressed bytes divided by zipir\'s at the same lane. "+25% size" means the '
    'peer wrote 25% more bytes.',
    '- **Compression ratio**: plaintext bytes divided by compressed bytes; higher is smaller output.',
    '- **MB/s**: plaintext (decoded) MB, 10^6 bytes, per second of median wall time, for both directions.',
    '- **Peak RSS**: the maximum resident set size of the whole process, as Zebrac reports it. It includes the '
    'program\'s runtime, libc for the C tools, I/O buffers, and codec state.',
    '- **Streaming**: the tool reads and writes through fixed buffers, so memory does not grow with the input. Every '
    'tool in this report streams; full-buffer decoders (such as libdeflate\'s one-shot API) are not in this run.',
]

METHOD = [
    '- **Matched rounds.** All tools for one file and operation run in one Zebrac batch: 3 warmup rounds, then exactly '
    '25 measured rounds, each round running every command once in a changing order. Load on the machine then slows '
    'every tool in the same rounds, which keeps the ratios fair. Times are medians of the 25 rounds.',
    '- **Whole commands.** Each sample is a complete process: start-up, reading the input file, and writing the '
    'output to `/dev/null` (or to a pipe Zebrac discards). This is what a user running the command sees, not a '
    'library inner loop.',
    '- **Correctness before timing.** Every tool was qualified on these files before it was timed: decoded bytes '
    'match an independent reference (GNU gzip, Python zlib, or a BGZF block walker that shares no code with zipir), '
    'and compressed output decodes back to the input with the reference decoder and with the tool itself. During the '
    'run, each compressor\'s output was decoded again and compared with the input.',
    '- **Same inputs.** Every tool in a batch reads the same file; compression reads the plaintext from the page cache.',
    '- **One thread.** Every tool runs single-threaded (`bgzip -@1`, no ISA-L threads); zipir is single-threaded by '
    'design.',
]

TOOLS_TEXT = [
    '- **zipir** 0.1.2 at the commit above: the four `tools/` adapters (`zipir-gzip`, `-zlib`, `-deflate`, `-bgzf`), '
    'which import the library directly. Zig 0.16.0, ReleaseFast, `-Dcpu=native`, stripped, single-threaded.',
    '- **zlib-ng** 2.3.3: the `minigzip` CLI for gzip; for zlib and raw DEFLATE, a small C adapter over its native API '
    '(`windowBits` 15 and -15). Static, `WITH_NATIVE_INSTRUCTIONS`, library defaults otherwise.',
    '- **ISA-L igzip** 2.32.1: the `igzip` CLI, static, one thread, native build.',
    '- **Zig std** 0.16.0: `std.compress.flate` through a Zig adapter, ReleaseFast, native CPU.',
    '- **bgzip** from htslib 1.24, `-@1`: once with libdeflate 1.26 (static; the configuration bioconda ships) and '
    'once with zlib-ng 2.3.3 in zlib-compatible mode (static). htslib\'s default compiler flags; the codec libraries '
    'use native instructions.',
    '- Every build targets this host\'s CPU (Zen 2: AVX2 is the widest vector extension available). A binary built '
    'here assumes AVX2; this report does not describe older x86-64 CPUs.',
]

LIMITS = [
    '- One machine, one CPU model. ARM64 and macOS are compile-tested only; their speed is not measured.',
    '- Large files (about 125 MB to 235 MB compressed) are not in this run, and Silesia (generalized medium) is measured for '
    'decompression only: its level 9 compression by the slowest peers takes over an hour per batch.',
    '- Peers outside this set (libdeflate\'s own CLI, GNU gzip, the host zlib, pigz, Rust flate2) passed the '
    'correctness checks on the sanity and small files but were not timed in this run.',
    '- zipir has three levels; peers offer more. The curves compare three points per tool, not full frontiers.',
    '- The results compare command-line tools, including start-up and file I/O; they do not rank library cores.',
]


def join_names(names):
    names = list(names)
    return names[0] if len(names) == 1 else ', '.join(names[:-1]) + ' and ' + names[-1]


def noise_lines(rows):
    """The run's own noise checks, computed from the data rather than asserted."""
    sel = [r for r in rows if r['class'] in CLASSES]
    batches = {(r['format'], r['op'], r['category'], r['class']) for r in sel}
    spreads = [100 * (r['wall_q3_ns'] / r['wall_q1_ns'] - 1) for r in sel]
    over = [r for r in sel if 100 * (r['wall_q3_ns'] / r['wall_q1_ns'] - 1) > 6]
    zipir = {(r['format'], r['op'], r['category'], r['class'], r['level']): r['mbs'] for r in sel if r['family'] == 'zipir'}
    worst = 0.0
    pairs = 0
    for (fmt, op, cat, cls, level), mbs in zipir.items():
        if fmt != 'deflate':
            continue
        for other in (('zlib',) if op == 'decompress' else ('zlib', 'gzip')):
            peer = zipir.get((other, op, cat, cls, level))
            if peer:
                pairs += 1
                worst = max(worst, abs(mbs / peer - 1) * 100)
    lines = [f'- **Disturbed batches.** Other work on the machine can slow a block of rounds for every tool in a batch, '
             f'which widens the spread of the 25 rounds. A batch where any tool\'s middle half of rounds spreads more '
             f'than 6% (third quartile over first) is re-timed. In the {len(batches)} batches of this report the largest '
             f'spread is {max(spreads):.1f}%' + (f'; {len(over)} rows still exceed 6% and are marked in '
                                                 f'`measurements.tsv`.' if over else '; none exceeds 6%.')]
    lines.append(f'- **Consistency.** zipir\'s results on the same stream in different containers must agree: raw '
                 f'DEFLATE against zlib decode of the same DEFLATE stream, and raw DEFLATE against zlib and gzip '
                 f'compression of the same plaintext (their checksums cost a few percent). This catches a batch slowed '
                 f'as a whole, which keeps a tight spread. Largest difference in this run: {worst:.1f}% over {pairs} '
                 f'pairs.')
    lines.append('- **Re-timing.** Batches that failed either check were re-timed with `tools/bench.sh --force` before '
                 'this report was generated; the tables show the re-timed values.')
    return lines


def reading_lines(summary, rows):
    """Plain statements generated from the summary rows; formats with the same result share one clause."""
    out = []
    by = {(s['op'], s['format'], s['lane']): s for s in summary}
    dec = [by[('decompress', f, None)] for f in FORMATS if ('decompress', f, None) in by]
    wins = [FORMAT_NAME[s['format']] for s in dec if s['fastest']['time'] > 1.02]
    ties = [(FORMAT_NAME[s['format']], s['fastest']) for s in dec if abs(s['fastest']['time'] - 1) <= 0.02]
    losses = [(FORMAT_NAME[s['format']], s['fastest']) for s in dec if s['fastest']['time'] < 0.98]
    if wins:
        out.append(f'Decompression: zipir is the fastest tool on {join_names(wins)}.')
    for name, f in ties:
        out.append(f'Decompression: on {name}, zipir and {FAMILY_NAME[f["family"]]} are level on average; per file '
                   f'the peer ranges from {1 / f["time_hi"]:.2f}x to {1 / f["time_lo"]:.2f}x zipir\'s speed.')
    for name, f in losses:
        out.append(f'Decompression: on {name}, {FAMILY_NAME[f["family"]]} is {1 / f["time"]:.2f}x faster than zipir '
                   f'on average ({1 / f["time_hi"]:.2f}x to {1 / f["time_lo"]:.2f}x across files).')
    for lane in LANES:
        items = [by[('compress', f, lane)] for f in FORMATS if ('compress', f, lane) in by]
        clauses = defaultdict(list)
        for s in items:
            e = s['equal']
            if e is None:
                clauses['no peer reaches zipir\'s output size on {}'].append(FORMAT_NAME[s['format']])
            elif e['time'] > 1:
                clauses['no peer with output no larger than zipir\'s is faster on {}'].append(FORMAT_NAME[s['format']])
            else:
                key = f'{FAMILY_NAME[e["family"]]} {e["level"]} is {1 / e["time"]:.2f}x faster at no larger output on {{}}'
                clauses[key].append(FORMAT_NAME[s['format']])
        parts = [template.format(join_names(names)) for template, names in clauses.items()]
        f_any = min((s['fastest'] for s in items), key=lambda f: f['time'])
        parts.append(f'the fastest peer at any size is {FAMILY_NAME[f_any["family"]]} {f_any["level"]}, '
                     f'{1 / f_any["time"]:.1f}x faster with {100 * (f_any["size"] - 1):.0f}% larger output'
                     if f_any['size'] > 1 else
                     f'the fastest peer at any size is {FAMILY_NAME[f_any["family"]]} {f_any["level"]}, {1 / f_any["time"]:.1f}x faster')
        out.append(f'Compression level {LANE_LEVEL[lane]} ({lane}): ' + '; '.join(parts) + '.')
    mem = [r['rss_median_bytes'] / 1048576 for r in rows if r['class'] in CLASSES and r['family'] == 'zipir']
    peers = [r['rss_median_bytes'] / 1048576 for r in rows if r['class'] in CLASSES and r['family'] not in ('zipir', 'zig-std')]
    out.append(f'Memory: zipir peaks at {min(mem):.2f} to {max(mem):.2f} MiB on every path; the C tools peak at '
               f'{min(peers):.1f} to {max(peers):.1f} MiB (whole process, see [Memory](#memory)).')
    return out


def compression_table(rows, fmt):
    sel = [r for r in rows if r['format'] == fmt and r['op'] == 'compress' and r['class'] in CLASSES]
    inputs = sorted({(r['category'], r['class']) for r in sel}, key=lambda k: (list(CATEGORY_NAME).index(k[0]), k[1] != 'medium'))
    header = ['Tool', 'Level'] + [f'{input_label(next(r for r in sel if (r["category"], r["class"]) == k))}' for k in inputs]
    out = []
    for fam in FAMILY_ORDER:
        for level in sorted({r['level'] for r in sel if r['family'] == fam and r['level'] != '-'}, key=int):
            cells = [FAMILY_NAME[fam] if fam != 'zipir' else '**zipir**', level]
            for k in inputs:
                r = next((r for r in sel if r['family'] == fam and r['level'] == level and (r['category'], r['class']) == k), None)
                if r is None:
                    cells.append('')
                    continue
                rel = '' if fam == 'zipir' else f', {r["time_vs_zipir"]:.2f}x, {size_delta(r["size_vs_zipir"])}'
                cells.append(f'{r["mbs"]:.1f} MB/s, {r["ratio"]:.3f}{rel}')
            out.append(cells)
    return md_table(header, out)


def size_delta(size):
    delta = 100 * (size - 1)
    return '\u00b10%' if abs(delta) < 0.5 else (f'{delta:+.0f}%' if abs(delta) >= 1.5 else f'{delta:+.1f}%')


def decode_table(rows, fmt):
    sel = [r for r in rows if r['format'] == fmt and r['op'] == 'decompress' and r['class'] in CLASSES]
    inputs = sorted({(r['category'], r['class']) for r in sel}, key=lambda k: (list(CATEGORY_NAME).index(k[0]), k[1] != 'medium'))
    header = ['Tool'] + [input_label(next(r for r in sel if (r['category'], r['class']) == k)) for k in inputs]
    out = []
    for fam in FAMILY_ORDER:
        if not any(r['family'] == fam for r in sel):
            continue
        cells = [FAMILY_NAME[fam] if fam != 'zipir' else '**zipir**']
        for k in inputs:
            r = next((r for r in sel if r['family'] == fam and (r['category'], r['class']) == k), None)
            cells.append('' if r is None else f'{r["mbs"]:.0f} MB/s' + ('' if fam == 'zipir' else f', {r["time_vs_zipir"]:.2f}x'))
        out.append(cells)
    return md_table(header, out)


def memory_table(rows):
    sel = [r for r in rows if r['class'] in CLASSES]
    out = []
    for fam in FAMILY_ORDER:
        items = [r for r in sel if r['family'] == fam]
        if not items:
            continue
        dec = [r['rss_median_bytes'] / 1048576 for r in items if r['op'] == 'decompress']
        com = [r['rss_median_bytes'] / 1048576 for r in items if r['op'] == 'compress']
        span = lambda v: (f'{min(v):.2f} to {max(v):.2f}' if max(v) < 1 else f'{min(v):.1f} to {max(v):.1f}') if v else ''
        out.append([FAMILY_NAME[fam] if fam != 'zipir' else '**zipir**', span(dec), span(com)])
    return md_table(['Tool', 'Decompression peak RSS (MiB)', 'Compression peak RSS (MiB)'], out, ['---', '---:', '---:'])


def efficiency_table(rows):
    sel = [r for r in rows if r['family'] == 'zipir' and r['class'] == 'medium' and r['cycles']]
    out = []
    for r in sorted(sel, key=lambda r: (FORMATS.index(r['format']), r['op'] != 'compress', r['category'], r['level'])):
        path = f'{FORMAT_NAME[r["format"]]} {r["op"]}' + (f' {r["level"]}' if r['level'] != '-' else '')
        out.append([path, input_label(r), f'{r["cycles"] / r["plain_bytes"]:.2f}', f'{r["instructions"] / r["plain_bytes"]:.2f}',
                    f'{r["instructions"] / r["cycles"]:.2f}', f'{r["mbs"]:.1f}'])
    return md_table(['Path', 'Input', 'Cycles / byte', 'Instructions / byte', 'IPC', 'MB/s'], out,
                    ['---', '---', '---:', '---:', '---:', '---:'])


def inputs_table(rows):
    seen = {}
    for r in rows:
        if r['class'] not in CLASSES:
            continue
        seen.setdefault((r['category'], r['class'], r['format']), r)
    out = []
    for (cat, cls, fmt), r in sorted(seen.items(), key=lambda kv: (list(CATEGORY_NAME).index(kv[0][0]), kv[0][1] != 'small', FORMATS.index(kv[0][2]))):
        ops = sorted({x['op'] for x in rows if (x['category'], x['class'], x['format']) == (cat, cls, fmt)})
        out.append([CATEGORY_NAME[cat], cls, FORMAT_NAME[fmt], f'`{r["file"]}`', f'{r["plain_bytes"] / 1e6:.1f} MB',
                    f'{r["input_bytes"] / 1e6:.1f} MB', ', '.join(ops)])
    return md_table(['Category', 'Class', 'Format', 'File', 'Plaintext', 'Stored', 'Operations'], out)


def write_tsv(rows, summary, meta, out):
    cols = ['format', 'op', 'category', 'class', 'file', 'tool', 'level', 'lane', 'samples', 'wall_median_ns',
            'wall_q1_ns', 'wall_q3_ns', 'wall_min_ns', 'wall_max_ns', 'rss_median_bytes', 'rss_max_bytes',
            'plain_bytes', 'input_bytes', 'compressed_bytes', 'mbs', 'ratio', 'time_vs_zipir', 'size_vs_zipir',
            'rss_vs_zipir', 'spread_pct', 'cycles', 'instructions']
    with open(out / 'measurements.tsv', 'w') as f:
        f.write(f'# zipir {meta["commit"]}; {meta["cpu"]}; {meta["kernel"]}; generated by bench/report.py from '
                f'run {meta["run"]}\n')
        f.write('\t'.join(cols) + '\n')
        for r in sorted(rows, key=lambda r: (r['format'], r['op'], r['category'], r['class'], r['tool'], r['level'])):
            vals = []
            for c in cols:
                v = r.get(c)
                vals.append('' if v is None else (f'{v:.6g}' if isinstance(v, float) else str(v)))
            f.write('\t'.join(vals) + '\n')
    with open(out / 'summary.tsv', 'w') as f:
        f.write('op\tformat\tlevel\tfiles\tfastest_tool\tfastest_level\tfastest_time_ratio\tfastest_time_min\t'
                'fastest_time_max\tfastest_size_ratio\tequal_tool\tequal_level\tequal_time_ratio\tequal_size_ratio\t'
                'zipir_mbs_min\tzipir_mbs_max\n')
        for s in summary:
            fa, e = s['fastest'], s['equal']
            f.write('\t'.join(str(x) for x in [
                s['op'], s['format'], LANE_LEVEL[s['lane']] if s['lane'] else '-', s['files'], fa['tool'], fa['level'],
                f'{fa["time"]:.4f}', f'{fa["time_lo"]:.4f}', f'{fa["time_hi"]:.4f}', f'{fa["size"]:.4f}',
                e['tool'] if e else '', e['level'] if e else '', f'{e["time"]:.4f}' if e else '',
                f'{e["size"]:.4f}' if e else '', f'{s["zipir_mbs_lo"]:.1f}', f'{s["zipir_mbs_hi"]:.1f}']) + '\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run', nargs='?', default='prime-lanes')
    ap.add_argument('--target', default='linux-x86-avx2')
    ap.add_argument('--frontier', action='append', default=[],
                    help='a run that timed every peer level (repeat for several formats), for the frontier figures')
    args = ap.parse_args()
    rows, meta = load(args.run)
    meta['run'] = args.run
    meta['cpu'] = (meta['cpu_model'] or 'unknown CPU').replace(' 16-Core Processor', '')
    meta['kernel'] = meta['kernel'] or 'Linux'
    meta['governor'] = pathlib.Path('/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor').read_text().strip()
    meta['gcc'] = subprocess.run(['gcc', '-dumpfullversion'], capture_output=True, text=True).stdout.strip()
    stamp = max(p.stat().st_mtime for p in (ROOT / 'tools/.local/bench' / args.run).glob('*/*/*.json'))
    meta['date'] = datetime.datetime.fromtimestamp(stamp).strftime('%Y-%m-%d')  # the host's local date
    if args.frontier:
        meta['frontier'] = load_frontier(args.frontier)
        meta['frontier_runs'] = args.frontier
    out = ROOT / 'bench' / args.target
    (out / 'figures').mkdir(parents=True, exist_ok=True)
    summary = summary_rows(rows)
    for theme in ('light', 'dark'):
        figure_summary(summary, meta, theme, out / 'figures' / f'summary-{theme}.svg')
        for fmt in FORMATS:
            figure_tradeoff(rows, fmt, theme, out / 'figures' / f'tradeoff-{fmt}-{theme}.svg')
        figure_decode(rows, theme, out / 'figures' / f'decode-{theme}.svg')
        figure_memory(rows, theme, out / 'figures' / f'memory-{theme}.svg')
        figure_memory_summary(rows, meta, theme, out / 'figures' / f'memory-summary-{theme}.svg')
        for fmt in FRONTIER:
            if any(r['format'] == fmt for r in meta.get('frontier', [])):
                figure_frontier(rows, meta['frontier'], fmt, theme, out / 'figures' / f'frontier-{fmt}-{theme}.svg')
    write_tsv(rows, summary, meta, out)
    write_readme(args.target, rows, summary, meta, out)
    print(f'wrote {out.relative_to(ROOT)}: README.md, measurements.tsv, summary.tsv, '
          f'figures/ ({len(list((out / "figures").glob("*.svg")))} SVG)')


if __name__ == '__main__':
    main()
