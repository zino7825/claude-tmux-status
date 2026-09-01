#!/usr/bin/env bash
# csm.sh — csm 의 bash 판. python3 가 없는 서버용이다.
#
#   csm.sh                 상태 표
#   csm.sh jump <N>        해당 세션의 창으로 이동
#   csm.sh next            내 차례인 창(! → ? → ✓ 순)으로 이동
#   csm.sh watch           2초마다 갱신. 숫자키로 점프, q 로 종료
#   csm.sh hook <event>    Claude Code 훅 (payload 는 stdin JSON)
#   csm.sh sweep           집계만 다시 (tmux status-interval 이 부른다)
#   csm.sh tmux-conf       ~/.tmux.conf 에 붙일 블록 출력
#   csm.sh install         훅 등록 + ~/.local/bin/csm 심링크 + tmux.conf 블록
#
# 필요한 것: bash 3.2+, tmux, jq, awk, ps.  (python 판은 python3 만 있으면 된다)
# 캐시 형식·상태 규칙은 python 판(csm)과 같다 — 둘 다 같은 ~/.cache/claude-tmux 를 읽는다.
# 규칙을 고칠 때는 반드시 둘 다 고치고 `compat-test.sh` 로 결과를 맞춰라.
#
# 훅은 이벤트마다 돌기 때문에 **프로세스를 몇 번 띄우느냐**가 곧 지연이다(fork 하나에 3~4ms).
# 집계는 awk 한 번, 캐시 읽기는 jq 한 번으로 몰아 두었다. 루프 안에서 cut/grep/sort/
# basename/date 를 쓰지 말 것 — 그렇게 짰던 판은 훅 한 번에 94개를 띄웠다(470ms).
set -uo pipefail

CACHE_DIR="$HOME/.cache/claude-tmux"
SELF="$(cd "${0%/*}" 2>/dev/null && pwd)/${0##*/}"
MARK='◆'
SHELLS=' zsh bash sh fish tcsh ksh dash '
STALL=180
SWEEP_GAP=5
T=$'\t'
NIL='-'                         # 행 안의 빈 값 자리표시자 (탭이 연달아 오면 read 가 뭉갠다)
AMBI="${CSM_AMBIWIDTH:-2}"      # ambiguous 글자 폭. 1 로 되돌릴 수 있다
NOW="$(date +%s)"               # 한 번만 구한다

command -v tmux >/dev/null 2>&1 || exit 0

SOCKET="${TMUX%%,*}"            # pane 안(훅·popup)이면 tmux 를 부를 필요가 없다
socket_path() {
  if [ -z "$SOCKET" ]; then     # 밖에서 부른 경우만 한 번 물어본다
    SOCKET="$(tmux display-message -p '#{socket_path}' 2>/dev/null)"
  fi
  printf '%s' "$SOCKET"
}

PANE_FMT="#{pane_id}${T}#{window_id}${T}#{window_index}${T}#{pane_current_command}${T}#{window_name}${T}#{pane_pid}${T}#{pane_current_path}${T}#{@claude_label}${T}#{@claude_state}"

# ── 집계 (awk 한 번) ─────────────────────────────────────────────────────
# 입력(태그 붙은 TSV):
#   S 스냅샷  pane win idx cmd wname pid path label wstate
#   C 캐시    file pane socket state ts turn tools tool agents agents_done pre post cwd task
#   P ps      pid ppid args   (캐시 없는 claude 후보가 있을 때만 넘긴다)
# 출력:
#   ROW  표에 쓸 행 (정렬 완료)   RM  지울 캐시 파일
#   WIN  창에 걸 tmux 명령         SUM status-right 요약
STATE_AWK='
function isclaude(a,   x) { x = a; sub(/ .*/, "", x)
  return (x ~ /\/claude$/ || x == "claude") && x !~ /^\/Applications\// }
function under(root, p,   q, n) {
  q = PAR[p]; n = 0
  while (q != "" && n++ < 50) { if (q == root) return 1; q = PAR[q] }
  return 0
}
function prio(s) {
  return (s == "input") ? 4 : (s == "stall") ? 3 : (s == "done") ? 2 \
       : (s == "working") ? 1 : (s == "start") ? 0 : -1
}
function glyph(s) {
  return (s == "working") ? "▶" : (s == "done") ? "✓" : (s == "input") ? "!" \
       : (s == "stall") ? "?" : "·"
}
function shortel(d) {
  if (d < 60) return ""
  if (d < 3600) return int(d / 60) "m"
  return int(d / 3600) "h" sprintf("%02d", int((d % 3600) / 60)) "m"
}
function base(p,   n) { n = p; sub(/\/+$/, "", n); sub(/^.*\//, "", n); return n }
function strip_glyphs(n,   i, g, k) {
  sub("^" MARK, "", n)
  k = index(n, "×"); if (k > 0) n = substr(n, 1, k - 1)
  split("▶|✓|!|?|·|⚙", g, "|")
  for (i = 1; i <= 6; i++) { k = index(n, g[i]); if (k > 0) n = substr(n, 1, k - 1) }
  return n
}
BEGIN { FS = OFS = "\t"; NROW = 0; NP = 0; NW = 0; NCL = 0 }
# 스냅샷은 태그 없이 9칸으로 온다 (C 는 15칸, P 는 4칸이라 겹치지 않는다)
NF == 9 && $1 ~ /^%/ {
  p = $1
  SW[p] = $2; SI[p] = $3; SC[p] = $4; SN[p] = $5; SP[p] = $6; SPATH[p] = $7
  PANES[++NP] = p
  if (!($2 in WSEEN)) { WSEEN[$2] = 1; WINS[++NW] = $2
                        WNAME[$2] = $5; WLABEL[$2] = $8; WSTATE[$2] = $9 }
  next
}
$1 == "P" { PAR[$2] = $3; if (isclaude($4)) CL[++NCL] = $2; next }
$1 == "C" {
  file = $2; p = $3
  if (!(p in SW)) { if ($4 != "" && $4 == MYSOCK) print "RM", file; next }
  if (index(SHELLS, " " SC[p] " ")) { print "RM", file; next }
  st = ($5 == "") ? "done" : $5
  ts = $6 + 0; turn = $7 + 0; tools = $8 + 0; tool = $9
  ag = $10 - $11; if (ag < 0) ag = 0
  infl = $12 - $13; if (infl < 0) infl = 0
  if (st == "working" && infl <= 0 && NOW - ts > STALL) st = "stall"
  HAVE[p] = 1
  NROW++
  R[NROW] = p OFS SW[p] OFS SI[p] OFS SN[p] OFS st OFS ts OFS turn OFS tools \
            OFS (tool == "" ? NIL : tool) OFS ag OFS infl \
            OFS ($14 == "" ? NIL : $14) OFS ($15 == "" ? NIL : $15)
  RST[NROW] = st; RIDX[NROW] = SI[p] + 0; RPANE[NROW] = p; RWIN[NROW] = SW[p]; RTS[NROW] = ts
  next
}
END {
  # 캐시가 없는데 claude 가 살아 있는 pane (훅 달기 전에 띄운 세션 등)
  for (i = 1; i <= NP; i++) {
    p = PANES[i]
    if (HAVE[p] || index(SHELLS, " " SC[p] " ")) continue
    found = 0
    for (j = 1; j <= NCL; j++) if (under(SP[p], CL[j])) { found = 1; break }
    if (!found) continue
    NROW++
    R[NROW] = p OFS SW[p] OFS SI[p] OFS SN[p] OFS "unknown" OFS 0 OFS 0 OFS 0 \
              OFS NIL OFS 0 OFS 0 OFS (SPATH[p] == "" ? NIL : SPATH[p]) OFS NIL
    RST[NROW] = "unknown"; RIDX[NROW] = SI[p] + 0; RPANE[NROW] = p
    RWIN[NROW] = SW[p]; RTS[NROW] = 0
  }

  # 정렬: 상태 우선순위 내림 → window index → pane (행이 적어 삽입 정렬로 충분)
  for (i = 1; i <= NROW; i++) O[i] = i
  for (i = 2; i <= NROW; i++) {
    v = O[i]; j = i - 1
    while (j >= 1) {
      a = O[j]
      if (prio(RST[a]) > prio(RST[v])) break
      if (prio(RST[a]) == prio(RST[v]) && RIDX[a] < RIDX[v]) break
      if (prio(RST[a]) == prio(RST[v]) && RIDX[a] == RIDX[v] && RPANE[a] < RPANE[v]) break
      O[j + 1] = a; j--
    }
    O[j + 1] = v
  }
  for (i = 1; i <= NROW; i++) print "ROW", R[O[i]]

  # 창별 갱신
  for (w = 1; w <= NW; w++) {
    win = WINS[w]; best = 0; cnt = 0; bts = -1
    for (i = 1; i <= NROW; i++) {
      if (RWIN[i] != win) continue
      cnt++
      if (best == 0 || prio(RST[i]) > prio(RST[best]) ||
          (prio(RST[i]) == prio(RST[best]) && RTS[i] > bts)) { best = i; bts = RTS[i] }
    }
    if (cnt == 0) {
      if (WLABEL[win] != "" || WSTATE[win] != "") {
        print "WIN", win, "unset", ""
        if (WNAME[win] != WLABEL[win]) print "WIN", win, "rename", WLABEL[win]
        print "WIN", win, "auto", ""
      }
      continue
    }
    split(R[best], f, OFS)
    st = f[5]; turn = f[7] + 0; tools = f[8] + 0; ag = f[10] + 0
    cwd = (f[12] == NIL) ? "" : f[12]
    label = WLABEL[win]
    if (label == "") {
      n = WNAME[win]
      if (index(n, MARK) == 1) label = strip_glyphs(n)
      else if (n == "node" || n == "claude" || n == "zsh" || n == "bash" ||
               n == "sh" || n == "fish" || n == "") label = ""
      else label = n
      if (label == "") label = base(cwd)
      if (label == "") label = "claude"
      print "WIN", win, "label", label
    }
    detail = ""
    if (st == "working") {
      if (tools > 0) detail = tools
      if (ag > 0) detail = detail "⚙" ag
      if (turn > 0) { e = shortel(NOW - turn); if (e != "") detail = detail "·" e }
    }
    target = MARK label (cnt > 1 ? "×" cnt : "") glyph(st) detail
    if (WNAME[win] != target) print "WIN", win, "rename", target
    if (WSTATE[win] != st) print "WIN", win, "state", st
  }

  # status-right 요약
  split("input stall done working unknown", ord, " ")
  split("!|?|✓|▶|·", gl, "|")
  sum = ""
  for (k = 1; k <= 5; k++) {
    c = 0
    for (i = 1; i <= NROW; i++) if (RST[i] == ord[k]) c++
    if (c > 0) sum = sum gl[k] c " "
  }
  sub(/ $/, "", sum)
  print "SUM", sum
}'

# 캐시 + 스냅샷 + (필요할 때만) ps 를 모아 awk 한 번에 넘긴다.
# 결과 행은 ROWS, 요약은 SUMMARY 에 담고 RM·WIN 지시는 여기서 실행한다.
ROWS=''; SUMMARY=''
state_pass() {   # $1=1 이면 창 이름·탭 색까지 갱신
  local apply="${1:-0}" snap files='' f p c need_ps=0 out kind a b rest
  snap="$(tmux list-panes -a -F "$PANE_FMT" 2>/dev/null)"
  ROWS=''; SUMMARY=''
  [ -n "$snap" ] || return

  for f in "$CACHE_DIR"/*.json; do [ -e "$f" ] && files="$files $f"; done
  while IFS="$T" read -r p _ _ c _; do          # 캐시 없는 claude 후보가 있을 때만 ps
    [ -n "$p" ] || continue
    case "$SHELLS" in *" $c "*) continue ;; esac
    [ -e "$CACHE_DIR/${p#%}.json" ] || need_ps=1
  done <<< "$snap"

  out="$(
    {
      printf '%s\n' "$snap"            # 태그 없이 넘긴다 — awk 가 필드 수로 구분한다
      if [ -n "$files" ]; then
        jq -r '[ "C", input_filename, .pane//"", .socket//"", .state//"", .ts//0, .turn_ts//0,
                 .tools//0, (.tool//""), .agents//0, .agents_done//0, .pre//0, .post//0,
                 (.cwd//""), (.task//"") ] | @tsv' $files 2>/dev/null
      fi
      if [ "$need_ps" = 1 ]; then
        ps -eo pid=,ppid=,args= 2>/dev/null |
          awk '{ pid = $1; ppid = $2; sub(/^[ ]*[0-9]+[ ]+[0-9]+[ ]+/, "")
                 print "P\t" pid "\t" ppid "\t" $0 }'
      fi
    } | awk -v NOW="$NOW" -v STALL="$STALL" -v MARK="$MARK" -v NIL="$NIL" \
            -v SHELLS="$SHELLS" -v MYSOCK="$(socket_path)" "$STATE_AWK"
  )"

  while IFS="$T" read -r kind a b rest; do
    case "$kind" in
      ROW) ROWS="${ROWS}${a}${T}${b}${T}${rest}
" ;;
      RM)  [ -n "$a" ] && rm -f "$a" 2>/dev/null ;;
      SUM) SUMMARY="$a" ;;
      WIN)
        [ "$apply" = 1 ] || continue
        case "$b" in
          rename) tmux rename-window -t "$a" "$rest" 2>/dev/null ;;
          state)  tmux set-option -w -t "$a" @claude_state "$rest" 2>/dev/null ;;
          label)  tmux set-option -w -t "$a" @claude_label "$rest" 2>/dev/null ;;
          unset)  tmux set-option -w -t "$a" -u @claude_label 2>/dev/null
                  tmux set-option -w -t "$a" -u @claude_state 2>/dev/null ;;
          auto)   tmux set-option -w -t "$a" automatic-rename on 2>/dev/null ;;
        esac ;;
    esac
  done <<< "$out"
}

# ── 표 (awk 한 번: 폭 계산·자르기·색) ────────────────────────────────────
LAYOUT_AWK='
function ord(c) { return ORD[c] }
function cpw(s,   i, n, b, cp, len, w) {
  w = 0; i = 1; n = length(s)
  while (i <= n) {
    b = ord(substr(s, i, 1))
    if (b < 128)      { cp = b; len = 1 }
    else if (b < 224) { cp = (b % 32) * 64 + (ord(substr(s, i+1, 1)) % 64); len = 2 }
    else if (b < 240) { cp = (b % 16) * 4096 + (ord(substr(s, i+1, 1)) % 64) * 64 + (ord(substr(s, i+2, 1)) % 64); len = 3 }
    else              { cp = 131072; len = 4 }
    w += cw(cp); i += len
  }
  return w
}
# python 판(csm)의 WIDE/AMB 표와 같은 값이어야 한다.
# ✓(0x2713) ⚙(0x2699) 은 Neutral 이라 1 칸 — ambiguous 로 넣으면 표가 어긋난다.
function cw(cp) {
  if ((cp >= 4352   && cp <= 4447)   ||
      (cp >= 11904  && cp <= 12350)  ||
      (cp >= 12353  && cp <= 13311)  ||
      (cp >= 13312  && cp <= 19903)  ||
      (cp >= 19968  && cp <= 40959)  ||
      (cp >= 40960  && cp <= 42191)  ||
      (cp >= 44032  && cp <= 55203)  ||
      (cp >= 63744  && cp <= 64255)  ||
      (cp >= 65072  && cp <= 65135)  ||
      (cp >= 65280  && cp <= 65376)  ||
      (cp >= 65504  && cp <= 65510)  ||
      (cp >= 127744 && cp <= 129791) ||
      (cp >= 131072)) return 2
  if ((cp >= 161   && cp <= 255)   ||
      (cp >= 8208  && cp <= 8254)  ||
      (cp >= 8448  && cp <= 8601)  ||
      (cp >= 8704  && cp <= 8959)  ||
      (cp >= 9312  && cp <= 9471)  ||
      (cp >= 9472  && cp <= 9599)  ||
      (cp >= 9632  && cp <= 9727)  ||
      (cp >= 9733  && cp <= 9734)  ||
      (cp == 9792) || (cp == 9794) ||
      (cp >= 9824  && cp <= 9829)  ||
      (cp >= 9834  && cp <= 9839)) return AMBI
  return 1
}
function pad(s, n,   w, r) { w = cpw(s); r = s; while (w++ < n) r = r " "; return r }
function clip(s, n,   i, b, len, out, w, ch) {
  if (n <= 0 || cpw(s) <= n) return s
  out = ""; w = 0; i = 1
  while (i <= length(s)) {
    b = ord(substr(s, i, 1))
    len = (b < 128) ? 1 : (b < 224) ? 2 : (b < 240) ? 3 : 4
    ch = substr(s, i, len)
    if (w + cpw(ch) > n - 1) break
    out = out ch; w += cpw(ch); i += len
  }
  return out "…"
}
function paint(s, c) { return (COLOR == 1 && c != "") ? c s RESET : s }
function ago(d) {
  if (d < 0) d = 0
  if (d < 60) return d "초 전"
  if (d < 3600) return int(d / 60) "분 전"
  if (d < 86400) return int(d / 3600) "시간 전"
  return int(d / 86400) "일 전"
}
function longel(d) {
  if (d < 60) return d "s"
  if (d < 3600) return int(d / 60) "m" sprintf("%02d", d % 60) "s"
  return int(d / 3600) "h" sprintf("%02d", int((d % 3600) / 60)) "m"
}
BEGIN {
  FS = "\t"
  for (i = 0; i < 256; i++) ORD[sprintf("%c", i)] = i
  RESET = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"
  COL["input"] = "\033[1;91m"; COL["stall"] = "\033[1;93m"; COL["done"] = "\033[1;92m"
  COL["working"] = "\033[96m"; COL["unknown"] = "\033[90m"
  N = 1
  C[1, 1] = "#"; C[1, 2] = "상태"; C[1, 3] = "window"; C[1, 4] = "tmux"
  C[1, 5] = "진행"; C[1, 6] = "마지막"; C[1, 7] = "cwd"; C[1, 8] = "작업"
  for (i = 1; i <= 8; i++) W[i] = cpw(C[1, i])
  MINE = 0; WORKN = 0; UNKN = 0
}
# pane win idx wname state ts turn tools tool agents inflight cwd task
NF >= 13 {
  N++
  st = $5; ST[N] = st
  lab = (st == "working") ? "▶ 작업중" : (st == "done") ? "✓ 완료" \
      : (st == "input") ? "! 응답대기" : (st == "stall") ? "? 확인필요" \
      : (st == "unknown") ? "· 상태없음" : "· " st
  prog = "-"
  if (st == "working" || st == "stall") {
    prog = $8 + 0
    if ($10 + 0 > 0) prog = prog " ⚙" ($10 + 0)
    if ($7 + 0 > 0) prog = prog " " longel(NOW - $7)
    if ($9 != NIL && $9 != "") prog = prog " " $9 (($11 + 0 > 0) ? "…" : "")
  }
  cwd = ($12 == NIL) ? "" : $12
  if (HOMEDIR != "" && index(cwd, HOMEDIR) == 1) cwd = "~" substr(cwd, length(HOMEDIR) + 1)
  C[N, 1] = N - 1; C[N, 2] = lab; C[N, 3] = $4; C[N, 4] = $3 "." $1
  C[N, 5] = prog; C[N, 6] = ($6 + 0 > 0) ? ago(NOW - $6) : "-"
  C[N, 7] = (cwd == "") ? "-" : cwd; C[N, 8] = ($13 == NIL) ? "-" : $13
  for (i = 1; i <= 8; i++) { w = cpw(C[N, i]); if (w > W[i]) W[i] = w }
  if (st == "input" || st == "done" || st == "stall") MINE++
  if (st == "working") WORKN++
  if (st == "unknown") UNKN++
}
END {
  if (N == 1) { print "실행 중인 Claude 세션이 없습니다."; exit }
  used = 0; for (i = 1; i <= 7; i++) used += W[i]
  room = TERM - used - 15; if (room < 10) room = 10
  if (W[8] > room) W[8] = room
  barw = used + W[8] + 14; if (barw > TERM - 1) barw = TERM - 1
  bar = ""; for (i = 0; i < barw; i++) bar = bar "─"
  for (r = 1; r <= N; r++) {
    line = ""
    for (i = 1; i <= 8; i++) {
      cell = pad((i == 8) ? clip(C[r, i], W[8]) : C[r, i], W[i])
      if (r == 1) cell = paint(cell, BOLD)
      else if (i == 1 || i == 8) cell = paint(cell, DIM)
      else if (i == 2 || i == 3) cell = paint(cell, COL[ST[r]])
      line = line (i > 1 ? "  " : "") cell
    }
    gsub(/[ \t]+$/, "", line)
    print line
    if (r == 1) print paint(bar, DIM)
  }
  print ""
  printf "%s%s%s\n", "내 차례 " MINE "개 · 작업중 " WORKN "개", \
         (UNKN > 0 ? " · 상태없음 " UNKN "개(훅 기록 전)" : ""), \
         paint("   —   csm jump <#> / csm next 로 이동", DIM)
}'

render() {   # $1=행들 $2=색(auto|0|1)
  local rows="$1" color="${2:-auto}" term
  if [ "$color" = auto ]; then
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then color=1; else color=0; fi
  fi
  if [ -z "$rows" ]; then echo "실행 중인 Claude 세션이 없습니다."; return; fi
  term="${COLUMNS:-0}"           # 터미널이 아니면 python 판과 같게 120 을 가정
  if [ "$term" -le 0 ] 2>/dev/null; then
    if [ -t 1 ]; then term="$(tput cols 2>/dev/null || echo 120)"; else term=120; fi
  fi
  [ "$term" -ge 60 ] 2>/dev/null || term=120
  printf '%s\n' "$rows" | LC_ALL=C awk -v TERM="$term" -v COLOR="$color" -v AMBI="$AMBI" \
    -v NOW="$NOW" -v NIL="$NIL" -v HOMEDIR="$HOME" "$LAYOUT_AWK"
}

nth_row() {   # $1=행들 $2=번호 → 그 줄
  local rows="$1" n="$2" i=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    i=$((i+1))
    [ "$i" = "$n" ] && { printf '%s' "$line"; return 0; }
  done <<< "$rows"
  return 1
}

goto_row() {
  local row="$1" pane win
  [ -n "$row" ] || return 1
  pane="${row%%$T*}"; row="${row#*$T}"; win="${row%%$T*}"
  tmux select-window -t "$win" 2>/dev/null
  tmux select-pane   -t "$pane" 2>/dev/null
  return 0
}

# ── sweep ───────────────────────────────────────────────────────────────
cmd_sweep() {   # $1=1 이면 재진입 방지를 건너뛴다
  local force="${1:-0}" tag stamp cached last sock
  [ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR" 2>/dev/null
  sock="$(socket_path)"; tag="${sock##*/}"; [ -n "$tag" ] || tag=default
  stamp="$CACHE_DIR/.sweep-$tag"; cached="$CACHE_DIR/.summary-$tag"
  if [ "$force" != 1 ]; then
    last=0; [ -r "$stamp" ] && read -r last < "$stamp" 2>/dev/null
    : "${last:=0}"
    if [ $(( NOW - last )) -lt "$SWEEP_GAP" ]; then
      [ -r "$cached" ] && cat "$cached"
      return
    fi
  fi
  printf '%s' "$NOW" > "$stamp" 2>/dev/null
  state_pass 1
  printf '%s' "$SUMMARY" > "$cached" 2>/dev/null
  printf '%s' "$SUMMARY"
}

# ── 훅 ──────────────────────────────────────────────────────────────────
esc() {   # JSON 문자열 이스케이프 (역슬래시·따옴표만 처리하면 된다 — 제어문자는 이미 걸렀다)
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

cmd_hook() {
  local STATE="${1:-done}" me payload sid cwd tool msg prompt line
  [ -n "${TMUX_PANE:-}" ] || return 0
  [ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR" 2>/dev/null
  me="$CACHE_DIR/${TMUX_PANE#%}.json"
  IFS= read -r -d '' payload 2>/dev/null || true   # cat 을 띄우지 않는다

  # 페이로드는 jq 한 번에 (예전엔 필드마다 jq 를 띄웠다)
  local pf=()
  while IFS= read -r line; do pf[${#pf[@]}]="$line"; done < <(
    printf '%s' "$payload" | jq -r '[.session_id//"", .cwd//"", .tool_name//"", .message//"",
      ((.prompt//"")|gsub("[\r\n\t]+";" ")|gsub("  +";" ")|.[0:120])] | .[]' 2>/dev/null)
  sid="${pf[0]:-}"; cwd="${pf[1]:-}"; tool="${pf[2]:-}"; msg="${pf[3]:-}"; prompt="${pf[4]:-}"

  if [ "$STATE" = end ]; then
    rm -f "$me" 2>/dev/null
    cmd_sweep 1 >/dev/null
    return 0
  fi

  local prev=()
  if [ -r "$me" ]; then          # 직전 상태도 jq 한 번, 줄 단위로 (빈 값이 밀리지 않게)
    while IFS= read -r line; do prev[${#prev[@]}]="$line"; done < <(
      jq -r '[.state//"", .turn_ts//0, .tools//0, .tool//"", .agents//0, .agents_done//0,
              .pre//0, .post//0, .session_id//"", .cwd//"", .task//""] | .[]' "$me" 2>/dev/null)
  fi
  local p_state="${prev[0]:-}" p_turn="${prev[1]:-0}" p_tools="${prev[2]:-0}" p_tool="${prev[3]:-}"
  local p_as="${prev[4]:-0}" p_ad="${prev[5]:-0}" p_pre="${prev[6]:-0}" p_post="${prev[7]:-0}"
  local p_sid="${prev[8]:-}" p_cwd="${prev[9]:-}" p_task="${prev[10]:-}"
  # 페이로드에 없으면 직전 값을 잇는다 (Stop 등은 cwd/session_id 가 비어 온다)
  [ -n "$sid" ] || sid="$p_sid"
  [ -n "$cwd" ] || cwd="${p_cwd:-$PWD}"

  local turn="$p_turn" tools="$p_tools" curtool="$p_tool" as="$p_as" ad="$p_ad"
  local pre="$p_pre" post="$p_post" task="$p_task"

  case "$STATE" in
    start|working)   # 새 턴 — 여기서만 done → working 으로 넘어간다
      turn="$NOW"; tools=0; as=0; ad=0; pre=0; post=0; curtool=''
      [ -z "$prompt" ] || task="$prompt"
      STATE=working ;;
    tool)            # PreToolUse — 지금 실제로 일하고 있다
      if [ "$p_state" = done ]; then turn="$NOW"; tools=0; as=0; ad=0; pre=0; post=0; fi
      pre=$((pre+1)); tools=$((tools+1)); curtool="$tool"
      case "$tool" in Task|Agent) as=$((as+1)) ;; esac
      case "$tool" in
        AskUserQuestion|ExitPlanMode) STATE=input ;;   # 반드시 사람 응답을 기다린다
        *) STATE=working ;;
      esac
      [ "$turn" -gt 0 ] 2>/dev/null || turn="$NOW" ;;
    tooldone)  # 완료 이벤트는 Stop 뒤에 늦게 올 수 있다 → 끝난 턴을 되살리지 않는다
      post=$((post+1)); [ -n "$tool" ] && curtool="$tool"
      if [ "$p_state" = done ]; then STATE=done; else STATE=working; fi ;;
    agent)
      ad=$((ad+1))
      if [ "$p_state" = done ]; then STATE=done; else STATE=working; fi ;;
    done)      STATE=done ;;
    input)     # 권한/승인 요청만 ! 로. 60초 idle 알림은 상태를 바꾸지 않는다
      case "$msg" in
        *ermission*|*pprove*|*confirm*|*권한*|*승인*) STATE=input ;;
        *) STATE="${p_state:-done}" ;;
      esac ;;
    *) return 0 ;;
  esac

  printf '{"pane":"%s","socket":"%s","state":"%s","session_id":"%s","cwd":"%s","ts":%s,"turn_ts":%s,"tools":%s,"tool":"%s","agents":%s,"agents_done":%s,"pre":%s,"post":%s,"task":"%s"}\n' \
    "$TMUX_PANE" "$(esc "${TMUX%%,*}")" "$STATE" "$(esc "$sid")" "$(esc "$cwd")" "$NOW" "$turn" \
    "$tools" "$(esc "$curtool")" "$as" "$ad" "$pre" "$post" "$(esc "$task")" > "$me" 2>/dev/null
  cmd_sweep 1 >/dev/null
  return 0
}

# ── tmux.conf 블록 ───────────────────────────────────────────────────────
BEGIN_MARK='# >>> csm >>>'
END_MARK='# <<< csm <<<'
# 예전 이름. 남의 conf 에 이미 박혀 있을 수 있어 설치할 때 같이 걷어낸다.
OLD_BEGIN='# >>> claude-agents tmux-state >>>'
OLD_END='# <<< claude-agents tmux-state <<<'

ver_ge() {  # $1 major $2 minor
  local v M m
  v="$(tmux -V 2>/dev/null)"; v="${v#tmux }"; v="${v#next-}"
  M="${v%%.*}"; m="${v#*.}"; m="${m%%[!0-9]*}"
  M="${M%%[!0-9]*}"
  [ -n "$M" ] || return 0
  [ "$M" -gt "$1" ] || { [ "$M" -eq "$1" ] && [ "${m:-0}" -ge "$2" ]; }
}

cmd_tmux_conf() {
  echo "$BEGIN_MARK"
  echo "# csm 이 만든 블록이다. 직접 고치지 말고 \`csm tmux-conf\` 를 다시 받아라."
  echo "#"
  echo "# 오른쪽에 전체 요약(! 응답대기 / ? 확인필요 / ✓ 완료 / ▶ 작업중 / · 상태없음)."
  echo "# status-interval 마다 sweep 이 돌아 창 이름의 경과시간·? 판정도 같이 갱신된다."
  echo "set -g status-interval 5"
  echo "set -g status-right '#[fg=colour39]#($SELF sweep)#[fg=white] %H:%M %d-%b-%y'"
  echo
  if ver_ge 3 1; then
    echo "# 상태별 탭 배경색. @claude_state 는 csm 이 window 옵션으로 세팅한다."
    echo "#   ! red / ? yellow / ✓ green / · gray(상태없음) / ▶·claude 없음 = 원래색"
    echo "# 현재 창은 window-status-current-format 이 따로 처리한다(\"지금 여기\"를 잃지 않게)."
    printf 'set -g window-status-format "#{?#{==:#{@claude_state},input},#[fg=colour231#,bg=colour160#,bold],#{?#{==:#{@claude_state},stall},#[fg=colour232#,bg=colour214#,bold],#{?#{==:#{@claude_state},done},#[fg=colour232#,bg=colour35#,bold],#{?#{==:#{@claude_state},unknown},#[fg=colour250#,bg=colour240],#[fg=white#,bg=colour234]}}}}#I.#W"\n'
  else
    echo "# 탭 색은 #{==:...} 가 필요해 tmux 3.1+ 에서만 된다. 창 이름 글리프로 대신한다."
  fi
  echo
  echo "# C-a L → csm 을 화면 위에. 숫자키로 이동, q 로 닫기."
  echo "unbind L"
  if ver_ge 3 2; then
    echo "bind-key L display-popup -E -w 90% -h 80% \"$SELF watch\""
  else
    echo "bind-key L new-window -n csm \"$SELF watch\""
  fi
  echo "$END_MARK"
}

# ── 설치 ────────────────────────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
OKM='  ✓'; WARNM='  ⚠'; FAILM='  ✗'

cmd_install() {
  local check=0; [ "${1:-}" = "--check" ] && check=1
  local bad=0
  chmod 755 "$SELF" 2>/dev/null

  # 한 local 문 안에서 앞의 변수를 참조하면 bash 3.2 는 아직 없는 값으로 본다 → 나눠 쓴다
  local bindir="$HOME/.local/bin"
  local link="$bindir/csm"
  local cur=''
  [ -L "$link" ] && cur="$(cd "$(dirname "$(readlink "$link")")" && pwd)/$(basename "$(readlink "$link")")"
  if [ "$cur" = "$SELF" ]; then echo "$OKM csm — 이미 연결됨"
  elif [ "$check" = 1 ]; then echo "$WARNM csm 심링크 없음"; bad=1
  else
    mkdir -p "$bindir"; rm -f "$link"; ln -s "$SELF" "$link"
    echo "$OKM csm → $link 심링크 생성"
  fi
  case ":$PATH:" in *":$bindir:"*) ;; *) echo "$WARNM PATH 에 $bindir 가 없다 — 셸 설정에 넣어라" ;; esac

  if ! command -v jq >/dev/null 2>&1; then
    echo "$FAILM jq 가 없다 — bash 판은 jq 가 필요하다 (python 판은 필요 없다)"
    return 1
  fi

  # 훅 등록: csm 을 부르는 항목만 손대고 나머지는 그대로 둔다
  local tmpf; tmpf="$(mktemp)"
  [ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
  if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "$FAILM settings.json 파싱 실패 — 훅 등록 중단"; rm -f "$tmpf"; return 1
  fi
  local changed='' ev arg want
  cp "$SETTINGS" "$tmpf"
  while read -r ev arg; do
    want="$SELF hook $arg"
    if EV="$ev" jq -e --arg w "$want" \
         '[(.hooks[$ENV.EV]//[])[].hooks[]? | select(.command == $w and .async == true)] | length > 0' \
         "$tmpf" >/dev/null 2>&1; then
      continue                       # 이미 같은 항목이 있다
    fi
    changed="$changed $ev"
    EV="$ev" jq --arg w "$want" '
      .hooks //= {} |
      .hooks[$ENV.EV] = ((.hooks[$ENV.EV]//[])
        | map(.hooks |= map(select((.command|test("csm|tmux-state\\.sh"))|not)))
        | map(select((.hooks|length) > 0)))
        + [{hooks:[{type:"command", command:$w, async:true}]}]' "$tmpf" > "$tmpf.new" && mv "$tmpf.new" "$tmpf"
  done <<EOF
SessionStart start
UserPromptSubmit working
PreToolUse tool
PostToolUse tooldone
SubagentStop agent
Notification input
Stop done
SessionEnd end
EOF
  if [ -z "$changed" ]; then echo "$OKM settings.json 훅 — 이미 최신"
  elif [ "$check" = 1 ]; then echo "$WARNM 훅 미등록/불일치:$changed"; bad=1
  else cp "$tmpf" "$SETTINGS"; chmod 600 "$SETTINGS"; echo "$OKM settings.json 훅 —$changed 등록"; fi
  rm -f "$tmpf" "$tmpf.new" 2>/dev/null

  # ~/.tmux.conf 블록
  local conf="$HOME/.tmux.conf" block body new
  block="$(cmd_tmux_conf)"
  body="$(cat "$conf" 2>/dev/null || true)"
  # 마커 사이만 갈아끼운다(옛 마커 블록도 같이 걷어낸다). awk -v 로는 여러 줄 블록을
  # 넘길 수 없어(newline in string) 셸 파라미터 확장으로 자른다.
  new="$body"
  if [ "${new#*$OLD_BEGIN}" != "$new" ] && [ "${new#*$OLD_END}" != "$new" ]; then
    new="${new%%$OLD_BEGIN*}${new#*$OLD_END}"
  fi
  if [ "${new#*$BEGIN_MARK}" != "$new" ] && [ "${new#*$END_MARK}" != "$new" ]; then
    new="${new%%$BEGIN_MARK*}${new#*$END_MARK}"
  fi
  while [ "${new%$'\n'}" != "$new" ]; do new="${new%$'\n'}"; done
  new="${new:+$new$'\n'$'\n'}$block"
  if [ "$new" = "$body" ]; then echo "$OKM .tmux.conf — 이미 최신"
  elif [ "$check" = 1 ]; then echo "$WARNM .tmux.conf 블록 미반영"; bad=1
  else
    [ -s "$conf" ] && cp "$conf" "$conf.csm-bak"
    printf '%s\n' "$new" > "$conf"
    echo "$OKM .tmux.conf — 블록 반영${body:+ (이전 파일은 $conf.csm-bak)}"
    if [ -n "${TMUX:-}" ] || tmux has-session >/dev/null 2>&1; then
      tmux source-file "$conf" 2>/dev/null && echo "$OKM tmux 설정 리로드"
    fi
  fi

  [ "$bad" = 1 ] && { echo "$FAILM 미설치 항목이 있다"; return 1; }
  echo "$OKM 완료. 새 Claude 세션부터 상태가 잡힌다."
  return 0
}

# ── 진입점 ──────────────────────────────────────────────────────────────
cmd_list() { state_pass 0; render "$ROWS"; }

cmd_watch() {
  if [ ! -t 1 ]; then cmd_list; return 0; fi     # claude 의 Bash 툴 등 — 무한 루프 금지
  local key
  while :; do
    NOW="$(date +%s)"
    state_pass 0
    printf '\033[H\033[2J'
    render "$ROWS"
    printf '\n1-9 이동 · q 닫기\n'
    key=''
    read -rsn1 -t 2 key 2>/dev/null
    case "$key" in
      q|Q|$'\e') break ;;
      [1-9]) goto_row "$(nth_row "$ROWS" "$key")" && break ;;
    esac
  done
}

case "${1:-list}" in
  list|-1|--once) cmd_list ;;
  jump)  [ $# -ge 2 ] || { echo "사용: csm jump <번호>" >&2; exit 1; }
         state_pass 0
         goto_row "$(nth_row "$ROWS" "$2")" || { echo "그런 번호가 없습니다: $2" >&2; exit 1; } ;;
  next)  state_pass 0
         pick=''
         for want in input stall done; do
           while IFS="$T" read -r p win idx wname st rest; do
             [ "${st:-}" = "$want" ] && { pick="$p$T$win"; break; }
           done <<< "$ROWS"
           [ -n "$pick" ] && break
         done
         [ -n "$pick" ] || { echo "내 차례인 세션이 없습니다." >&2; exit 1; }
         goto_row "$pick" ;;
  watch) cmd_watch ;;
  hook)  shift; cmd_hook "${1:-done}" ;;
  sweep) cmd_sweep ;;
  tmux-conf|conf) cmd_tmux_conf ;;
  install) shift; cmd_install "${1:-}" ;;
  -h|--help|help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "사용: csm.sh [list|jump <#>|next|watch|hook <event>|sweep|tmux-conf|install]" >&2; exit 1 ;;
esac
