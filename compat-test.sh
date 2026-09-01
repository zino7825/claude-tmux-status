#!/usr/bin/env bash
# Prove that csm (python) and csm.sh (bash) behave identically.
#
#   ./compat-test.sh
#
# The two editions share one cache (~/.cache/claude-tmux) and every state rule, so
# changing only one of them drifts silently. Run this after touching a rule. Your real
# sessions are never touched: everything happens on a throwaway tmux server (-L csmtest).
set -uo pipefail
cd "$(dirname "$0")"

SOCK=csmtest
CACHE="$HOME/.cache/claude-tmux"
fail=0
say() { printf '%s %s\n' "$1" "$2"; }
ok()  { say '  ✓' "$1"; }
bad() { say '  ✗' "$1"; fail=1; }

cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null; rm -f "$PY_JSON" "$SH_JSON" 2>/dev/null; }
trap cleanup EXIT

tmux -L "$SOCK" kill-server 2>/dev/null
tmux -L "$SOCK" new-session -d -s t -x 150 -y 40 'sleep 120' || { echo "tmux not found"; exit 1; }
tmux -L "$SOCK" new-window -d 'sleep 120'
SOCKET_PATH="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
PANE_PY="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
PANE_SH="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | tail -1)"
PY_JSON="$CACHE/${PANE_PY#%}.json"
SH_JSON="$CACHE/${PANE_SH#%}.json"
# Leftover state from an earlier run would make the comparison meaningless
rm -f "$PY_JSON" "$SH_JSON" "$CACHE/.sweep-$(basename "$SOCKET_PATH")" \
      "$CACHE/.summary-$(basename "$SOCKET_PATH")" 2>/dev/null

# Freeze the clock for both editions from the very start: the two hook runs happen a
# moment apart, so without this turn_ts/ts differ by a second now and then.
export CSM_NOW="$(date +%s)"

# ── 1. state machine: feed the same event sequence to both ──────────────
feed() {  # $1=impl $2=pane $3=event $4=payload
  local cmd=(./csm hook "$3")
  [ "$1" = sh ] && cmd=(./csm.sh hook "$3")
  printf '%s' "$4" | env TMUX="$SOCKET_PATH,1,0" TMUX_PANE="$2" "${cmd[@]}" >/dev/null 2>&1
}
EVENTS=(
  'working|{"session_id":"s1","cwd":"'"$HOME"'/git","prompt":"긴  프롬프트\t탭과 \"따옴표\" 포함"}'
  'tool|{"tool_name":"Bash"}'
  'tool|{"tool_name":"Task"}'
  'tooldone|{"tool_name":"Bash"}'
  'agent|{}'
  'tool|{"tool_name":"AskUserQuestion"}'
  'input|{"message":"Claude needs your permission"}'
  'done|{}'
)
for e in "${EVENTS[@]}"; do
  feed py "$PANE_PY" "${e%%|*}" "${e#*|}"
  feed sh "$PANE_SH" "${e%%|*}" "${e#*|}"
done

norm() { jq -S 'del(.pane, .socket, .ts)' "$1" 2>/dev/null; }
if [ -f "$PY_JSON" ] && [ -f "$SH_JSON" ] && [ "$(norm "$PY_JSON")" = "$(norm "$SH_JSON")" ]; then
  ok "state machine — cache identical after 8 events"
else
  bad "state machine — caches differ"
  diff <(norm "$PY_JSON") <(norm "$SH_JSON") | sed 's/^/      /'
fi

# ── 2. table ────────────────────────────────────────────────────────────
# Looking at real sessions makes the comparison flaky (state changes between runs).
# Point both at the test server only, and freeze the timestamps an hour in the past.
export TMUX="$SOCKET_PATH,1,0"
# Freeze the clock for both editions: without this the "3m02s" style progress column
# can tick over between the two runs and the diff reports a difference that is not one.
FIXED=$(( CSM_NOW - 3600 ))
cat > "$PY_JSON" <<JSON
{"pane":"$PANE_PY","socket":"$SOCKET_PATH","state":"done","session_id":"s1",
 "cwd":"$HOME/git/some-project","ts":$FIXED,"turn_ts":$FIXED,"tools":7,"tool":"Bash",
 "agents":2,"agents_done":1,"pre":3,"post":3,
 "task":"한글 프롬프트 \"따옴표\" 와 긴 꼬리 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
JSON
cat > "$SH_JSON" <<JSON
{"pane":"$PANE_SH","socket":"$SOCKET_PATH","state":"working","session_id":"s2",
 "cwd":"/tmp","ts":$FIXED,"turn_ts":$FIXED,"tools":0,"tool":"","agents":0,"agents_done":0,
 "pre":1,"post":0,"task":""}
JSON
for lang in en ko; do
  for a in 1 2; do
    for w in 120 90; do
      if diff -q <(COLUMNS=$w CSM_AMBIWIDTH=$a CSM_LANG=$lang NO_COLOR=1 ./csm.sh list) \
                 <(COLUMNS=$w CSM_AMBIWIDTH=$a CSM_LANG=$lang NO_COLOR=1 ./csm list) >/dev/null; then
        ok "table — lang=$lang ambi=$a cols=$w"
      else
        bad "table — lang=$lang ambi=$a cols=$w differs"
        diff <(COLUMNS=$w CSM_AMBIWIDTH=$a CSM_LANG=$lang NO_COLOR=1 ./csm.sh list) \
             <(COLUMNS=$w CSM_AMBIWIDTH=$a CSM_LANG=$lang NO_COLOR=1 ./csm list) | sed 's/^/      /' | head -8
      fi
    done
  done
done

# ── 3. tmux.conf block (only the self path differs) ─────────────────────
strip_self() { sed -e "s#$PWD/csm.sh#CSM#g" -e "s#$PWD/csm#CSM#g"; }
if diff -q <(./csm.sh tmux-conf | strip_self) <(./csm tmux-conf | strip_self) >/dev/null; then
  ok "tmux.conf block identical"
else
  bad "tmux.conf block differs"
  diff <(./csm.sh tmux-conf | strip_self) <(./csm tmux-conf | strip_self) | sed 's/^/      /'
fi

# ── 4. sweep: summary and window names ──────────────────────────────────
names() { tmux -L "$SOCK" list-windows -a -F '#{window_index} #{window_name} #{@claude_state}'; }
rm -f "$CACHE/.sweep-$(basename "$SOCKET_PATH")"
sh_sum="$(./csm.sh sweep)"; sh_names="$(names)"
rm -f "$CACHE/.sweep-$(basename "$SOCKET_PATH")"
py_sum="$(./csm sweep)"; py_names="$(names)"
[ "$sh_sum" = "$py_sum" ] && ok "sweep summary identical ($py_sum)" || bad "sweep summary: bash='$sh_sum' python='$py_sum'"
[ "$sh_names" = "$py_names" ] && ok "window names and tab states identical" || {
  bad "window names and tab states differ"; diff <(printf '%s\n' "$sh_names") <(printf '%s\n' "$py_names") | sed 's/^/      /'; }

echo
[ "$fail" = 0 ] && echo "both editions agree." || echo "they differ — fix the items above."
exit "$fail"
