#!/usr/bin/env python3
"""The README banner: wordmark + a mini tab bar in the real state colours."""
import html, sys

W, H = 1000, 212
CELL = 8.6
FONT = ("ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Monaco, 'Cascadia Mono', "
        "'Roboto Mono', Consolas, 'DejaVu Sans Mono', monospace")
RED, GREEN, AMBER = "#d70000", "#00af5f", "#ffaf00"
DARK, INK, MUTE = "#1c1f26", "#c9d1d9", "#8b949e"

def cw(ch):
    return 2 if 0x1100 <= ord(ch) <= 0x115F or 0xAC00 <= ord(ch) <= 0xD7A3 else 1

def chip(x, y, text, fg, bg, bold=False):
    w = sum(cw(c) for c in text) * CELL + 14
    wt = ' font-weight="700"' if bold else ''
    out = [f'<rect x="{x:.1f}" y="{y}" width="{w:.1f}" height="26" rx="4" fill="{bg}"/>',
           f'<text x="{x+7:.1f}" y="{y+18}" fill="{fg}" font-size="14"{wt}'
           f' xml:space="preserve">{html.escape(text)}</text>']
    return "".join(out), x + w + 8

lang = sys.argv[1] if len(sys.argv) > 1 else "en"
tag = {"en": "Claude Code session status in tmux",
       "ko": "Claude Code 세션 상태를 tmux 에"}[lang]
sub = {"en": "which window is waiting for me — answered in the tab bar",
       "ko": "어느 창이 내 차례인가 — 탭 바가 바로 답한다"}[lang]

s = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
     f'font-family="{FONT}">',
     '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
     '<stop offset="0" stop-color="#14161b"/><stop offset="0.55" stop-color="#191d24"/>'
     '<stop offset="1" stop-color="#121418"/></linearGradient></defs>',
     f'<rect width="{W}" height="{H}" rx="14" fill="url(#g)"/>',
     f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="13.5" fill="none" stroke="#262b34"/>',
     # the ◆ mark, drawn so it does not depend on a font
     '<path d="M48 60 L60 48 L72 60 L60 72 Z" fill="#61afef"/>',
     '<text x="86" y="76" font-size="54" font-weight="700" fill="#e6edf3" '
     'letter-spacing="1">csm</text>',
     f'<text x="88" y="108" font-size="19" fill="{INK}">{html.escape(tag)}</text>',
     f'<text x="88" y="132" font-size="14" fill="{MUTE}">{html.escape(sub)}</text>']

x, y = 48, 156
for text, fg, bg, bold in (("0.◆infra!", "#ffffff", RED, True),
                           ("1.◆web✓", "#121212", GREEN, True),
                           ("2.◆api▶12⚙1·3m", INK, DARK, False),
                           ("3.◆etl?", "#121212", AMBER, True),
                           ("4.◆ui·", INK, DARK, False),
                           ("5.notes", MUTE, "#171a20", False)):
    piece, x = chip(x, y, text, fg, bg, bold)
    s.append(piece)
s.append(f'<text x="{W-48}" y="{y+18}" text-anchor="end" font-size="14" fill="#61afef" '
         f'font-weight="700" xml:space="preserve">!1 ?1 ✓1 ▶1</text>')
s.append("</svg>")
open(sys.argv[2], "w").write("\n".join(s))
print(sys.argv[2])
