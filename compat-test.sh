#!/usr/bin/env bash
# csm(python) 과 csm.sh(bash) 가 같은 결과를 내는지 확인한다.
#
#   ./compat-test.sh
#
# 두 판은 같은 캐시(~/.cache/claude-tmux)와 같은 상태 규칙을 공유한다. 한쪽만 고치면
# 조용히 어긋나므로 규칙을 건드렸으면 이걸 돌려라. 진짜 세션은 건드리지 않는다 —
# 전용 tmux 서버(-L csmtest)를 띄우고 그 안의 pane 으로만 시험한다.
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
tmux -L "$SOCK" new-session -d -s t -x 150 -y 40 'sleep 120' || { echo "tmux 없음"; exit 1; }
tmux -L "$SOCK" new-window -d 'sleep 120'
SOCKET_PATH="$(tmux -L "$SOCK" display-message -p '#{socket_path}')"
PANE_PY="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | head -1)"
PANE_SH="$(tmux -L "$SOCK" list-panes -a -F '#{pane_id}' | tail -1)"
PY_JSON="$CACHE/${PANE_PY#%}.json"
SH_JSON="$CACHE/${PANE_SH#%}.json"
# 앞선 시험이 남긴 상태가 섞이면 비교가 무의미하다
rm -f "$PY_JSON" "$SH_JSON" "$CACHE/.sweep-$(basename "$SOCKET_PATH")" \
      "$CACHE/.summary-$(basename "$SOCKET_PATH")" 2>/dev/null

# ── 1. 상태 기계: 같은 이벤트 열을 두 판에 먹인다 ──────────────────────
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
  ok "상태 기계 — 8개 이벤트 후 캐시 동일"
else
  bad "상태 기계 — 캐시가 다르다"
  diff <(norm "$PY_JSON") <(norm "$SH_JSON") | sed 's/^/      /'
fi

# ── 2. 표 ──────────────────────────────────────────────────────────────
# 진짜 세션을 보면 두 번 돌리는 사이에 상태가 바뀌어 비교가 흔들린다.
# 시험 서버(TMUX=csmtest)만 보게 하고, 시각도 한 시간 전으로 고정한다.
export TMUX="$SOCKET_PATH,1,0"
FIXED=$(( $(date +%s) - 3600 ))
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
for a in 1 2; do
  for w in 120 90; do
    if diff -q <(COLUMNS=$w CSM_AMBIWIDTH=$a NO_COLOR=1 ./csm.sh list) \
               <(COLUMNS=$w CSM_AMBIWIDTH=$a NO_COLOR=1 ./csm list) >/dev/null; then
      ok "표 — AMBI=$a COLUMNS=$w 동일"
    else
      bad "표 — AMBI=$a COLUMNS=$w 차이"
      diff <(COLUMNS=$w CSM_AMBIWIDTH=$a NO_COLOR=1 ./csm.sh list) \
           <(COLUMNS=$w CSM_AMBIWIDTH=$a NO_COLOR=1 ./csm list) | sed 's/^/      /' | head -8
    fi
  done
done

# ── 3. tmux.conf 블록 (자기 경로만 다르다) ──────────────────────────────
strip_self() { sed -e "s#$PWD/csm.sh#CSM#g" -e "s#$PWD/csm#CSM#g"; }
if diff -q <(./csm.sh tmux-conf | strip_self) <(./csm tmux-conf | strip_self) >/dev/null; then
  ok "tmux.conf 블록 동일"
else
  bad "tmux.conf 블록 차이"
  diff <(./csm.sh tmux-conf | strip_self) <(./csm tmux-conf | strip_self) | sed 's/^/      /'
fi

# ── 4. sweep: 요약 + 창 이름 ────────────────────────────────────────────
names() { tmux -L "$SOCK" list-windows -a -F '#{window_index} #{window_name} #{@claude_state}'; }
rm -f "$CACHE/.sweep-$(basename "$SOCKET_PATH")"
sh_sum="$(./csm.sh sweep)"; sh_names="$(names)"
rm -f "$CACHE/.sweep-$(basename "$SOCKET_PATH")"
py_sum="$(./csm sweep)"; py_names="$(names)"
[ "$sh_sum" = "$py_sum" ] && ok "sweep 요약 동일 ($py_sum)" || bad "sweep 요약: bash='$sh_sum' python='$py_sum'"
[ "$sh_names" = "$py_names" ] && ok "창 이름·탭 상태 동일" || {
  bad "창 이름·탭 상태 차이"; diff <(printf '%s\n' "$sh_names") <(printf '%s\n' "$py_names") | sed 's/^/      /'; }

echo
[ "$fail" = 0 ] && echo "두 판이 같은 결과를 낸다." || echo "차이가 있다 — 위 항목을 맞춰라."
exit "$fail"
