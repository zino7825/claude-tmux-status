#!/usr/bin/env python3
"""ANSI terminal capture -> SVG, for README screenshots.

Per-character x positions, so the picture lines up in any monospace font.
"""
import html, re, sys

CELL_W, CELL_H, FONT = 8.6, 19.0, 14.5
PAD_X, PAD_TOP, PAD_BOT = 18, 16, 16
BAR_H = 0                       # set by --chrome
BG = "#15171c"
FG = "#c9d1d9"
FONT_STACK = ("ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Monaco, "
              "'Cascadia Mono', 'Roboto Mono', Consolas, 'DejaVu Sans Mono', monospace")

# 16 base colours (a calm dark terminal theme)
BASE16 = ["#2b2f38", "#e05561", "#5fb85f", "#d2a24c", "#4d9de0", "#b877db", "#48b0bd", "#c9d1d9",
          "#5c6370", "#ff6b74", "#7ddb7d", "#f0c674", "#61afef", "#d19ae8", "#56c8d8", "#ffffff"]

def xterm256():
    pal = list(BASE16)
    lv = [0, 95, 135, 175, 215, 255]
    for r in lv:
        for g in lv:
            for b in lv:
                pal.append("#%02x%02x%02x" % (r, g, b))
    for i in range(24):
        v = 8 + i * 10
        pal.append("#%02x%02x%02x" % (v, v, v))
    return pal

PAL = xterm256()
WIDE = ((0x1100, 0x115F), (0x2E80, 0x303E), (0x3041, 0x33FF), (0x3400, 0x4DBF),
        (0x4E00, 0x9FFF), (0xA000, 0xA4CF), (0xAC00, 0xD7A3), (0xF900, 0xFAFF),
        (0xFE30, 0xFE6F), (0xFF00, 0xFF60), (0xFFE0, 0xFFE6), (0x1F300, 0x1FAFF),
        (0x20000, 0x3FFFD))

def cw(ch):                     # ambiguous = 1, matching tmux's own grid
    cp = ord(ch)
    return 2 if any(lo <= cp <= hi for lo, hi in WIDE) else 1

SGR_RE = re.compile(r"\x1b\[([0-9;]*)m")

class Style:
    __slots__ = ("fg", "bg", "bold", "dim", "rev", "und")
    def __init__(self):
        self.fg = self.bg = None
        self.bold = self.dim = self.rev = self.und = False
    def copy(self):
        s = Style(); s.fg, s.bg = self.fg, self.bg
        s.bold, s.dim, s.rev, s.und = self.bold, self.dim, self.rev, self.und
        return s
    def key(self):
        return (self.fg, self.bg, self.bold, self.dim, self.rev, self.und)

def apply(st, params):
    codes = [int(p) if p else 0 for p in params.split(";")] or [0]
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0: st.__init__()
        elif c == 1: st.bold = True
        elif c == 2: st.dim = True
        elif c == 4: st.und = True
        elif c == 7: st.rev = True
        elif c in (21, 22): st.bold = st.dim = False
        elif c == 24: st.und = False
        elif c == 27: st.rev = False
        elif 30 <= c <= 37: st.fg = c - 30
        elif c == 39: st.fg = None
        elif 40 <= c <= 47: st.bg = c - 40
        elif c == 49: st.bg = None
        elif 90 <= c <= 97: st.fg = c - 90 + 8
        elif 100 <= c <= 107: st.bg = c - 100 + 8
        elif c in (38, 48) and i + 1 < len(codes):
            which = "fg" if c == 38 else "bg"
            if codes[i + 1] == 5 and i + 2 < len(codes):
                setattr(st, which, codes[i + 2]); i += 2
            elif codes[i + 1] == 2 and i + 4 < len(codes):
                setattr(st, which, "#%02x%02x%02x" % tuple(codes[i + 2:i + 5])); i += 4
        i += 1

def colour(v, default):
    if v is None: return default
    if isinstance(v, str): return v
    return PAL[v] if v < len(PAL) else default

def parse(text):
    """-> list of rows; each row is a list of (char, Style)."""
    rows = []
    for line in text.split("\n"):
        st, cells, pos = Style(), [], 0
        while pos < len(line):
            m = SGR_RE.search(line, pos)
            if m and m.start() == pos:
                apply(st, m.group(1)); pos = m.end(); continue
            end = m.start() if m else len(line)
            for ch in line[pos:end]:
                cells.append((ch, st.copy()))
            pos = end
        rows.append(cells)
    return rows

def render(rows, chrome=True, title=""):
    while rows and not any(c.strip() for c, _ in rows[-1]): rows.pop()
    while rows and not any(c.strip() for c, _ in rows[0]): rows.pop(0)
    cols = max((sum(cw(c) for c, _ in r) for r in rows), default=0)
    bar = 34 if chrome else 0
    w = cols * CELL_W + 2 * PAD_X
    h = len(rows) * CELL_H + PAD_TOP + PAD_BOT + bar
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
           f'viewBox="0 0 {w:.0f} {h:.0f}" font-family="{FONT_STACK}" font-size="{FONT}">',
           f'<rect width="{w:.0f}" height="{h:.0f}" rx="10" fill="{BG}"/>']
    if chrome:
        out.append(f'<rect width="{w:.0f}" height="{bar}" rx="10" fill="#20232b"/>')
        out.append(f'<rect y="{bar-10}" width="{w:.0f}" height="10" fill="#20232b"/>')
        out.append(f'<line x1="0" y1="{bar}" x2="{w:.0f}" y2="{bar}" stroke="#2c3038"/>')
        for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")):
            out.append(f'<circle cx="{20+i*18}" cy="{bar/2:.0f}" r="5.5" fill="{c}"/>')
        if title:
            out.append(f'<text x="{w/2:.0f}" y="{bar/2+4.5:.0f}" text-anchor="middle" '
                       f'font-size="12" fill="#6b7280">{html.escape(title)}</text>')
    rects, texts = [], []
    for ri, row in enumerate(rows):
        y = bar + PAD_TOP + ri * CELL_H
        base = y + CELL_H - 5.5
        col = 0
        runs = []                      # (startcol, chars, style)
        for ch, st in row:
            k = st.key()
            if runs and runs[-1][2].key() == k:
                runs[-1][1].append((col, ch))
            else:
                runs.append((col, [(col, ch)], st))
            col += cw(ch)
        for start, chars, st in runs:
            fg = colour(st.fg, FG); bg = colour(st.bg, None)
            if st.rev: fg, bg = (bg or BG), fg
            width = sum(cw(c) for _, c in chars)
            if bg:
                rects.append(f'<rect x="{PAD_X+start*CELL_W:.1f}" y="{y:.1f}" '
                             f'width="{width*CELL_W:.1f}" height="{CELL_H:.1f}" fill="{bg}"/>')
            s = "".join(c for _, c in chars)
            if not s.strip(): continue
            xs = " ".join(f"{PAD_X+c*CELL_W:.1f}" for c, _ in chars)
            attrs = f'fill="{fg}"'
            if st.bold: attrs += ' font-weight="600"'
            if st.dim: attrs += ' fill-opacity="0.58"'
            if st.und: attrs += ' text-decoration="underline"'
            texts.append(f'<text x="{xs}" y="{base:.1f}" xml:space="preserve" {attrs}>'
                         f'{html.escape(s)}</text>')
    out += rects + texts
    out.append("</svg>")
    return "\n".join(out)

if __name__ == "__main__":
    args = sys.argv[1:]
    chrome = "--bare" not in args
    args = [a for a in args if a != "--bare"]
    title = ""
    if "--title" in args:
        i = args.index("--title"); title = args[i + 1]; args = args[:i] + args[i + 2:]
    src, dst = args[0], args[1]
    data = open(src, encoding="utf-8", errors="replace").read()
    data = data.replace("\x1b[?25l", "").replace("\x1b[?25h", "").replace("\r", "")
    data = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", lambda m: m.group(0) if m.group(0).endswith("m") else "", data)
    data = data.replace("\x04", "").replace("\x08", "")
    open(dst, "w", encoding="utf-8").write(render(parse(data), chrome, title))
    print(dst)
