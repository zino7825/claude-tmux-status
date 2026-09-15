#!/bin/bash
# Regenerate the README pictures.
#
# Everything here is a real capture: a throwaway tmux server is filled with a
# fixed set of sessions, csm is run against it for real, and the terminal output
# is turned into SVG by ansi2svg.py. Nothing is hand-drawn except banner.py.
#
#   ./docs/shots.sh          # docs/*.svg
#
# The demo server is its own tmux socket and its own cache keys, so it cannot
# touch the state of the sessions you are actually running.
set -uo pipefail
cd "$(dirname "$0")/.."
DOCS=docs
DEMO=csmdemo SHOT=csmshot TBL=csmtbl
CACHE="$HOME/.cache/claude-tmux"
PANES="0 1 2 3 4"

command -v tmux >/dev/null || { echo "tmux not found"; exit 1; }
for s in "$DEMO" "$SHOT" "$TBL"; do tmux -L "$s" kill-server 2>/dev/null; done
cleanup() {
  for s in "$DEMO" "$SHOT" "$TBL"; do tmux -L "$s" kill-server 2>/dev/null; done
  for p in $PANES; do rm -f "$CACHE/$p.json"; done
  rm -f /tmp/csm-shots.conf
}
trap cleanup EXIT

# ── the demo server ──────────────────────────────────────────────────────────
# -f /dev/null: your own ~/.tmux.conf must not leak into the picture.
LC_ALL=en_US.UTF-8 tmux -L "$DEMO" -f /dev/null new-session -d -s demo -x 118 -y 19 'sleep 1800' || exit 1
for _ in 1 2 3 4; do tmux -L "$DEMO" new-window -d 'sleep 1800'; done
tmux -L "$DEMO" new-window -d -n notes 'sleep 1800'        # a window with no claude in it
python3 csm tmux-conf > /tmp/csm-shots.conf
tmux -L "$DEMO" source-file /tmp/csm-shots.conf
tmux -L "$DEMO" set -g status-style 'bg=colour234,fg=colour250'
tmux -L "$DEMO" set -g status-left ''
tmux -L "$DEMO" set -g window-status-separator ' '
tmux -L "$DEMO" set -g window-status-current-format '#[fg=colour231,bold]#I.#W'
tmux -L "$DEMO" set-environment -g CSM_AMBIWIDTH 1   # tmux draws ◆ ▶ · one column wide
SOCKET="$(tmux -L "$DEMO" display-message -p '#{socket_path}')"
tmux -L "$DEMO" select-window -t 5
sleep 1                      # let the windows settle before csm renames them

seed() {  # $1 = en|ko
  python3 - "$1" "$SOCKET" "$DEMO" <<'PY'
import json, os, subprocess, sys, time
lang, sock, server = sys.argv[1], sys.argv[2], sys.argv[3]
T = int(time.time())
cache = os.path.expanduser("~/.cache/claude-tmux")
task = {"en": ["deploy the canary to two zones first", "fix the flaky checkout test",
               "add the rate limiter to the public API", "backfill last week's events", ""],
        "ko": ["카나리는 두 존만 먼저 배포해줘", "장바구니 테스트 깨지는 거 고쳐줘",
               "공개 API 에 레이트 리밋 붙여줘", "지난주 이벤트 백필해줘", ""]}[lang]
rows = [  # one per state the table can show
 ("0", "infra", dict(state="input",   ts=T-70,  turn_ts=T-95,  tools=3,  pre=3,  post=3,  tool="Edit")),
 ("1", "web",   dict(state="done",    ts=T-12,  turn_ts=T-140, tools=9,  pre=9,  post=9,  tool="Bash", agents=1, agents_done=1)),
 ("2", "api",   dict(state="working", ts=T-2,   turn_ts=T-182, tools=12, pre=13, post=12, tool="Bash", agents=1)),
 ("3", "etl",   dict(state="working", ts=T-420, turn_ts=T-640, tools=5,  pre=5,  post=5,  tool="WebFetch")),  # -> stall
 ("4", "ui",    dict(state="start",   ts=T-4)),
]
for (pane, label, st), t in zip(rows, task):
    st.update(socket=sock, session_id="demo-" + pane, task=t,
              cwd=os.path.expanduser("~/src/") + label)
    json.dump(st, open(os.path.join(cache, pane + ".json"), "w"), ensure_ascii=False)
    subprocess.run(["tmux", "-L", server, "set-option", "-w", "-t", "%" + pane,
                    "@claude_label", label])
PY
}

capture() {  # $1 = en|ko
  local L=$1
  seed "$L"
  tmux -L "$DEMO" set-environment -g CSM_LANG "$L"
  TMUX="$SOCKET,1,0" CSM_AMBIWIDTH=1 python3 csm sweep >/dev/null

  # the tab bar and the C-a L popup: attach to the demo server from a second
  # server, so capture-pane sees the whole inner screen, status line included.
  tmux -L "$SHOT" kill-server 2>/dev/null
  LC_ALL=en_US.UTF-8 tmux -L "$SHOT" -f /dev/null new-session -d -s shot -x 118 -y 19 \
      "TMUX= tmux -L $DEMO attach -t demo"
  tmux -L "$SHOT" set -g status off; sleep 1
  tmux -L "$SHOT" capture-pane -p -e -t shot | tail -1 > "/tmp/csm-tabs.$L.ansi"
  tmux -L "$SHOT" send-keys -t shot C-b L; sleep 2
  tmux -L "$SHOT" capture-pane -p -e -t shot > "/tmp/csm-popup.$L.ansi"

  # plain `csm` in a plain terminal
  tmux -L "$TBL" kill-server 2>/dev/null
  LC_ALL=en_US.UTF-8 tmux -L "$TBL" -f /dev/null new-session -d -s t -x 114 -y 12 \
      "CSM_LANG=$L CSM_AMBIWIDTH=1 TMUX=$SOCKET,1,0 sh -c 'cd $PWD; python3 csm; sleep 600'"
  tmux -L "$TBL" set -g status off; sleep 2
  tmux -L "$TBL" capture-pane -p -e -t t > "/tmp/csm-table.$L.ansi"
}

capture en
python3 "$DOCS/ansi2svg.py" --title tmux /tmp/csm-popup.en.ansi "$DOCS/popup.svg"
python3 "$DOCS/ansi2svg.py" --title csm  /tmp/csm-table.en.ansi "$DOCS/table.svg"
python3 "$DOCS/ansi2svg.py" --bare       /tmp/csm-tabs.en.ansi  "$DOCS/tabs.svg"

capture ko
python3 "$DOCS/ansi2svg.py" --title tmux /tmp/csm-popup.ko.ansi "$DOCS/popup.ko.svg"
python3 "$DOCS/ansi2svg.py" --title csm  /tmp/csm-table.ko.ansi "$DOCS/table.ko.svg"

python3 "$DOCS/banner.py" en "$DOCS/banner.svg"
python3 "$DOCS/banner.py" ko "$DOCS/banner.ko.svg"
rm -f /tmp/csm-*.ansi
