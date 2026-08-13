#!/usr/bin/env python3
"""Render real accelerometer recordings as an SVG figure.

Every sample plotted comes from data/raw. Nothing is synthesised. The only
reduction is a min/max envelope per pixel column, which preserves peaks exactly.
Both rows share one vertical scale so the comparison between them is truthful.
"""
import struct, math, os

REC = 28
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "site", "img")
RAW = os.path.join(ROOT, "data", "raw")

W, ROW_H, PAD_T, PAD_B, GAP = 1200.0, 156.0, 34.0, 34.0, 96.0


def load(path, start_s, dur_s, rate):
    i0 = int(start_s * rate)
    n = int(dur_s * rate)
    with open(path, "rb") as f:
        f.seek(i0 * REC)
        b = f.read(n * REC)
    out = []
    for i in range(len(b) // REC):
        t, a, x, y, z = struct.unpack_from("<qqfff", b, i * REC)
        out.append(math.sqrt(x * x + y * y + z * z))
    return out


def envelope(mags, cols):
    """Min/max per column, in mg relative to the window mean."""
    mean = sum(mags) / len(mags)
    dev = [(m - mean) * 1000.0 for m in mags]
    per = len(dev) / cols
    env = []
    for c in range(cols):
        a, b = int(c * per), max(int((c + 1) * per), int(c * per) + 1)
        chunk = dev[a:b]
        env.append((min(chunk), max(chunk)))
    return env


ROWS = [
    dict(
        path=f"{RAW}/idle__desk__20260813-213857__75bdf7/accel.bin",
        start=505.0, dur=60.0, rate=795.8,
        label="A real machine doing real work",
        sub="60 s from a 25-minute recording. Hard desk, Swift builds running, fans up.",
    ),
    dict(
        path=f"{RAW}/confound_music__desk__20260813-213400__93cb8f/accel.bin",
        start=0.0, dur=90.0, rate=796.2,
        label="Bass-heavy music through the desk",
        sub="The full 90 s recording. 45, 60 and 80 Hz layered bass, laptop speakers at 55.",
    ),
]


def build():
    cols = int(W)
    peak = 0.0
    for r in ROWS:
        r["env"] = envelope(load(r["path"], r["start"], r["dur"], r["rate"]), cols)
        peak = max(peak, max(max(abs(lo), abs(hi)) for lo, hi in r["env"]))
    scale = (ROW_H / 2 - 6) / peak

    H = PAD_T + len(ROWS) * ROW_H + (len(ROWS) - 1) * GAP + PAD_B
    p = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}" '
        f'width="{W:.0f}" height="{H:.0f}" role="img" aria-label="Two real accelerometer '
        f'recordings from a MacBook on a hard desk, drawn to the same vertical scale. '
        f'The upper trace is 60 seconds of a 25-minute session with the machine running Swift '
        f'builds; its loudest moment reaches about 74 milli-g. The lower trace is 90 seconds of '
        f'bass-heavy music played through the desk and stays near flat at about 3 milli-g. '
        f'Neither recording produced a trigger.">',
        """<style>
  /* Tokens from design/IDENTITY.md. The figure is graphite and aluminium
     only: the amber in this viewport is spent on the CTA. */
  .lbl{font:600 20px Inter,-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;fill:#16191E;letter-spacing:-.015em}
  .sub{font:400 14px Inter,-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;fill:#868D96}
  .axis{stroke:#000000;stroke-opacity:.10;stroke-width:1}
  .band{fill:#16191E;fill-opacity:.76}
  .peak{font:500 13px ui-monospace,SFMono-Regular,"SF Mono",Menlo,monospace;fill:#868D96;font-variant-numeric:tabular-nums}
  @media (prefers-color-scheme: dark){
    .lbl{fill:#E8EAED}
    .sub,.peak{fill:#9BA2AB}
    .axis{stroke:#FFFFFF;stroke-opacity:.14}
    .band{fill:#F2F5F8;fill-opacity:.82}
  }
</style>""",
    ]

    y = PAD_T
    for r in ROWS:
        mid = y + ROW_H / 2
        pk = max(max(abs(lo), abs(hi)) for lo, hi in r["env"])
        p.append(f'<text class="lbl" x="0" y="{y - 13:.0f}">{r["label"]}</text>')
        p.append(f'<line class="axis" x1="0" y1="{mid:.1f}" x2="{W:.0f}" y2="{mid:.1f}"/>')
        top = " ".join(f"{c},{mid - hi * scale:.1f}" for c, (lo, hi) in enumerate(r["env"]))
        bot = " ".join(f"{c},{mid - lo * scale:.1f}" for c, (lo, hi) in reversed(list(enumerate(r["env"]))))
        p.append(f'<path class="band" d="M {top} L {bot} Z"/>')
        p.append(f'<text class="sub" x="0" y="{y + ROW_H + 24:.0f}">{r["sub"]}</text>')
        p.append(f'<text class="peak" x="{W:.0f}" y="{y + ROW_H + 24:.0f}" text-anchor="end">'
                 f'peak {pk:.0f} mg &#183; {r["dur"]:.0f} s at 796 Hz &#183; 0 triggers</text>')
        y += ROW_H + GAP

    p.append("</svg>")
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "trace-real.svg")
    with open(path, "w") as f:
        f.write("\n".join(p))
    print("wrote", path, f"| shared scale peak {peak:.1f} mg |",
          " ".join(f'{r["label"][:18]}={max(max(abs(a),abs(b)) for a,b in r["env"]):.1f}mg' for r in ROWS))


build()
