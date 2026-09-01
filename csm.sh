#!/usr/bin/env bash
# csm.sh — the bash edition of csm, for machines without python3.
#
#   csm.sh                 the table
#   csm.sh jump <N>        jump to that session's window
#   csm.sh next            jump to the window that needs you (! -> ? -> done)
#   csm.sh watch           refresh every 2s; digits jump, q quits
#   csm.sh hook <event>    Claude Code hook (payload is JSON on stdin)
#   csm.sh sweep           recompute only (called by tmux status-interval)
#   csm.sh tmux-conf       print the block for ~/.tmux.conf
#   csm.sh install         hooks + ~/.local/bin/csm symlink + tmux.conf block
#
# Needs: bash 3.2+, tmux, jq, awk, ps.  (the python edition needs only python3)
# Cache format and state rules match the python edition — both read ~/.cache/claude-tmux.
# Change a rule in both files and run `compat-test.sh` to prove they still agree.
#
# In a hook the cost is **how many processes you spawn**, not the computation
# (a fork is 3-4 ms). Aggregation is one awk pass and the cache is read by one jq call.
# Never call cut/grep/sort/basename/date inside a loop — a version that did spawned 94
# externals per event and took 470 ms.
set -uo pipefail

CACHE_DIR="$HOME/.cache/claude-tmux"
SELF="$(cd "${0%/*}" 2>/dev/null && pwd)/${0##*/}"
MARK='◆'
SHELLS=' zsh bash sh fish tcsh ksh dash '
STALL=180
SWEEP_GAP=5
T=$'\t'
NIL='-'                         # placeholder for empty fields (read collapses repeated tabs)
AMBI="${CSM_AMBIWIDTH:-2}"      # width of ambiguous glyphs; set 1 for narrow terminals
# Current time, once per run. CSM_NOW freezes it so compat-test.sh can compare two runs.
NOW="${CSM_NOW:-$(date +%s)}"

# Output language: $LANG decides, CSM_LANG overrides. The python edition carries the
# same two tables — compat-test.sh compares the rendered tables byte for byte.
case "${CSM_LANG:-${LANG:-}}" in
  ko|ko[_.]*) CSM_KO=1 ;;
  *)          CSM_KO=0 ;;
esac
if [ "$CSM_KO" = 1 ]; then
  T_WORKING='▶ 작업중'; T_DONE='✓ 완료'; T_INPUT='! 응답대기'
  T_STALL='? 확인필요'; T_UNKNOWN='· 상태없음'
  T_HDR="#${T}상태${T}window${T}tmux${T}진행${T}마지막${T}cwd${T}작업"
  T_SEC='초 전'; T_MIN='분 전'; T_HOUR='시간 전'; T_DAY='일 전'
  T_MINE='내 차례'; T_WORKN='작업중'; T_UNK='상태없음'
  T_HINT='   —   csm jump <#> / csm next 로 이동'
  T_KEYS='1-9 이동 · q 닫기'
  T_NONE='실행 중인 Claude 세션이 없습니다.'
  T_NOSESS='내 차례인 세션이 없습니다.'; T_NONUM='그런 번호가 없습니다: '
  T_USAGE_JUMP='사용: csm jump <번호>'
else
  T_WORKING='▶ working'; T_DONE='✓ done'; T_INPUT='! waiting'
  T_STALL='? quiet'; T_UNKNOWN='· unknown'
  T_HDR="#${T}state${T}window${T}tmux${T}progress${T}last${T}cwd${T}task"
  T_SEC='s ago'; T_MIN='m ago'; T_HOUR='h ago'; T_DAY='d ago'
  T_MINE='your turn'; T_WORKN='working'; T_UNK='no state yet'
  T_HINT='   —   csm jump <#> / csm next'
  T_KEYS='1-9 jump · q close'
  T_NONE='No Claude session is running.'
  T_NOSESS='No session is waiting for you.'; T_NONUM='no such row: '
  T_USAGE_JUMP='usage: csm jump <row>'
fi

command -v tmux >/dev/null 2>&1 || exit 0

SOCKET="${TMUX%%,*}"            # inside a pane (hook/popup) there is nothing to ask tmux
socket_path() {
  if [ -z "$SOCKET" ]; then     # only when called from outside tmux
    SOCKET="$(tmux display-message -p '#{socket_path}' 2>/dev/null)"
  fi
  printf '%s' "$SOCKET"
}

PANE_FMT="#{pane_id}${T}#{window_id}${T}#{window_index}${T}#{pane_current_command}${T}#{window_name}${T}#{pane_pid}${T}#{pane_current_path}${T}#{@claude_label}${T}#{@claude_state}"

# ── aggregation (one awk pass) ──────────────────────────────────────────
# Input (tagged TSV):
#   snapshot  pane win idx cmd wname pid path label wstate   (9 fields, untagged)
#   C cache   file pane socket state ts turn tools tool agents agents_done pre post cwd task
#   P ps      pid ppid args   (only sent when a pane has no cache entry)
# Output:
#   ROW  a table row (already sorted)   RM   cache file to delete
#   WIN  a tmux command to run          SUM  the status-right summary
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
# The snapshot arrives untagged with 9 fields (C has 15, P has 4, so they never collide)
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
  # Panes with a live claude but no cache (sessions started before the hooks were installed)
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

  # Sort by state priority desc, then window index, then pane (few rows: insertion sort)
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

  # per-window refresh
  for (w = 1; w <= NW; w++) {
    win = WINS[w]; best = 0; cnt = 0; bts = -1
    for (i = 1; i <= NROW; i++) {
      if (RWIN[i] != win) continue
      cnt++
      if (best == 0 || prio(RST[i]) > prio(RST[best]) ||
          (prio(RST[i]) == prio(RST[best]) && RTS[i] > bts)) { best = i; bts = RTS[i] }
    }
    if (cnt == 0) {                     # no claude here any more
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

  # status-right summary
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

# Feed cache + snapshot + (only if needed) ps to awk in one pass.
# Rows land in ROWS, the summary in SUMMARY; RM/WIN instructions are executed here.
ROWS=''; SUMMARY=''
state_pass() {   # $1=1 also refreshes window names and tab colours
  local apply="${1:-0}" snap files='' f p c need_ps=0 out kind a b rest
  snap="$(tmux list-panes -a -F "$PANE_FMT" 2>/dev/null)"
  ROWS=''; SUMMARY=''
  [ -n "$snap" ] || return

  for f in "$CACHE_DIR"/*.json; do [ -e "$f" ] && files="$files $f"; done
  while IFS="$T" read -r p _ _ c _; do          # ps only if some pane has no cache
    [ -n "$p" ] || continue
    case "$SHELLS" in *" $c "*) continue ;; esac
    [ -e "$CACHE_DIR/${p#%}.json" ] || need_ps=1
  done <<< "$snap"

  out="$(
    {
      printf '%s\n' "$snap"            # untagged; awk tells inputs apart by field count
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

# ── table (one awk pass: widths, clipping, colour) ──────────────────────
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
# Must match the WIDE/AMB tables in the python edition exactly.
# U+2713 and U+2699 are Neutral = 1 column; as ambiguous they shift the table by one.
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
  if (d < 60) return d T_SEC
  if (d < 3600) return int(d / 60) T_MIN
  if (d < 86400) return int(d / 3600) T_HOUR
  return int(d / 86400) T_DAY
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
  split(T_HDR, h, "\t")
  for (i = 1; i <= 8; i++) C[1, i] = h[i]
  for (i = 1; i <= 8; i++) W[i] = cpw(C[1, i])
  MINE = 0; WORKN = 0; UNKN = 0
}
# pane win idx wname state ts turn tools tool agents inflight cwd task
NF >= 13 {
  N++
  st = $5; ST[N] = st
  lab = (st == "working") ? T_WORKING : (st == "done") ? T_DONE \
      : (st == "input") ? T_INPUT : (st == "stall") ? T_STALL \
      : (st == "unknown") ? T_UNKNOWN : "· " st
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
  if (N == 1) { print T_NONE; exit }
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
  printf "%s%s%s\n", T_MINE ": " MINE " · " T_WORKN ": " WORKN, \
         (UNKN > 0 ? " · " T_UNK ": " UNKN : ""), paint(T_HINT, DIM)
}'

render() {   # $1=rows $2=colour (auto|0|1)
  local rows="$1" color="${2:-auto}" term
  if [ "$color" = auto ]; then
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then color=1; else color=0; fi
  fi
  if [ -z "$rows" ]; then echo "$T_NONE"; return; fi
  term="${COLUMNS:-0}"           # not a terminal: assume 120, same as the python edition
  if [ "$term" -le 0 ] 2>/dev/null; then
    if [ -t 1 ]; then term="$(tput cols 2>/dev/null || echo 120)"; else term=120; fi
  fi
  [ "$term" -ge 60 ] 2>/dev/null || term=120
  printf '%s\n' "$rows" | LC_ALL=C awk -v TERM="$term" -v COLOR="$color" -v AMBI="$AMBI" \
    -v NOW="$NOW" -v NIL="$NIL" -v HOMEDIR="$HOME" \
    -v T_WORKING="$T_WORKING" -v T_DONE="$T_DONE" -v T_INPUT="$T_INPUT" \
    -v T_STALL="$T_STALL" -v T_UNKNOWN="$T_UNKNOWN" -v T_HDR="$T_HDR" \
    -v T_SEC="$T_SEC" -v T_MIN="$T_MIN" -v T_HOUR="$T_HOUR" -v T_DAY="$T_DAY" \
    -v T_MINE="$T_MINE" -v T_WORKN="$T_WORKN" -v T_UNK="$T_UNK" -v T_HINT="$T_HINT" \
    -v T_NONE="$T_NONE" "$LAYOUT_AWK"
}

nth_row() {   # $1=rows $2=row number -> that line
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
cmd_sweep() {   # $1=1 skips the re-entry guard
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

# ── hook ────────────────────────────────────────────────────────────────
esc() {   # JSON string escape (backslash and quote only; control chars are already stripped)
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}

pane_owning() {   # pane whose process tree holds us, when the hook gets no TMUX_PANE
  # Claude Code can host a session under a daemon-spawned pty (`claude daemon run` ->
  # `claude --bg-pty-host`, which is what a resumed or forked session gets): the pane's
  # shell is still an ancestor, but TMUX_PANE is not in that environment. Without this
  # the hook wrote nothing and the row kept its pre-fork state forever.
  # Only the default server is reachable here - with no TMUX nothing names another socket.
  local map out
  map="$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null)" || return 1
  [ -n "$map" ] || return 1
  out="$( { printf '%s\n' "$map"; echo '--'; ps -eo pid=,ppid=; } | awk -v self=$$ '
    /^--$/            { sep = 1; next }
    !sep              { pane[$1] = $2; next }
                      { par[$1] = $2 }
    END { pid = self
          for (i = 0; i < 64 && pid != "" && pid != "0" && pid != "1"; i++) {
            if (pid in pane) { print pane[pid]; exit }
            pid = par[pid]
          } }')"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

cmd_hook() {
  local STATE="${1:-done}" me payload sid cwd tool msg prompt line PANE
  PANE="${TMUX_PANE:-}"
  if [ -z "$PANE" ]; then          # daemon-hosted session: the env is gone, the tree is not
    PANE="$(pane_owning)" || return 0
    [ -n "$PANE" ] || return 0
  fi
  [ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR" 2>/dev/null
  me="$CACHE_DIR/${PANE#%}.json"
  IFS= read -r -d '' payload 2>/dev/null || true   # builtin read, no cat process

  # Whole payload in one jq call (an earlier version spawned one per field)
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
  if [ -r "$me" ]; then          # previous state, one jq call, line by line so empties hold
    while IFS= read -r line; do prev[${#prev[@]}]="$line"; done < <(
      jq -r '[.state//"", .turn_ts//0, .tools//0, .tool//"", .agents//0, .agents_done//0,
              .pre//0, .post//0, .session_id//"", .cwd//"", .task//""] | .[]' "$me" 2>/dev/null)
  fi
  local p_state="${prev[0]:-}" p_turn="${prev[1]:-0}" p_tools="${prev[2]:-0}" p_tool="${prev[3]:-}"
  local p_as="${prev[4]:-0}" p_ad="${prev[5]:-0}" p_pre="${prev[6]:-0}" p_post="${prev[7]:-0}"
  local p_sid="${prev[8]:-}" p_cwd="${prev[9]:-}" p_task="${prev[10]:-}"
  # Carry the previous value when the payload omits it (Stop arrives without cwd/session_id)
  [ -n "$sid" ] || sid="$p_sid"
  [ -n "$cwd" ] || cwd="${p_cwd:-$PWD}"

  local turn="$p_turn" tools="$p_tools" curtool="$p_tool" as="$p_as" ad="$p_ad"
  local pre="$p_pre" post="$p_post" task="$p_task"

  case "$STATE" in
    start|working)   # new turn - the only done -> working transition
      turn="$NOW"; tools=0; as=0; ad=0; pre=0; post=0; curtool=''
      [ -z "$prompt" ] || task="$prompt"
      STATE=working ;;
    tool)            # PreToolUse - actually working right now
      if [ "$p_state" = done ]; then turn="$NOW"; tools=0; as=0; ad=0; pre=0; post=0; fi
      pre=$((pre+1)); tools=$((tools+1)); curtool="$tool"
      case "$tool" in Task|Agent) as=$((as+1)) ;; esac
      case "$tool" in
        AskUserQuestion|ExitPlanMode) STATE=input ;;   # these always wait for a human
        *) STATE=working ;;
      esac
      [ "$turn" -gt 0 ] 2>/dev/null || turn="$NOW" ;;
    tooldone)  # completion events can arrive after Stop; never resurrect a finished turn
      post=$((post+1)); [ -n "$tool" ] && curtool="$tool"
      if [ "$p_state" = done ]; then STATE=done; else STATE=working; fi ;;
    agent)
      ad=$((ad+1))
      if [ "$p_state" = done ]; then STATE=done; else STATE=working; fi ;;
    done)      STATE=done ;;
    input)     # only permission/approval prompts; the 60s idle notice changes nothing
      case "$msg" in
        # Korean strings kept: Claude Code localises this notification.
        *ermission*|*pprove*|*confirm*|*권한*|*승인*) STATE=input ;;
        *) STATE="${p_state:-done}" ;;
      esac ;;
    *) return 0 ;;
  esac

  printf '{"pane":"%s","socket":"%s","state":"%s","session_id":"%s","cwd":"%s","ts":%s,"turn_ts":%s,"tools":%s,"tool":"%s","agents":%s,"agents_done":%s,"pre":%s,"post":%s,"task":"%s"}\n' \
    "$PANE" "$(esc "$(socket_path)")" "$STATE" "$(esc "$sid")" "$(esc "$cwd")" "$NOW" "$turn" \
    "$tools" "$(esc "$curtool")" "$as" "$ad" "$pre" "$post" "$(esc "$task")" > "$me" 2>/dev/null
  cmd_sweep 1 >/dev/null
  return 0
}

# ── tmux.conf block ─────────────────────────────────────────────────────
BEGIN_MARK='# >>> csm >>>'
END_MARK='# <<< csm <<<'
# Older marker name; installs clean it out of confs that still carry it.
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
  echo "# Written by csm. Do not edit here - re-run \`csm tmux-conf\` instead."
  echo "#"
  echo "# status-right shows the totals (! waiting / ? quiet / ✓ done / ▶ working / · unknown)."
  echo "# The sweep also refreshes elapsed times and the quiet-too-long check."
  echo "set -g status-interval 5"
  echo "set -g status-right '#[fg=colour39]#($SELF sweep)#[fg=white] %H:%M %d-%b-%y'"
  echo
  if ver_ge 3 1; then
    echo "# Tab colour per state. csm sets @claude_state as a window option."
    echo "#   ! red / ? yellow / ✓ green / · grey (unknown) / ▶ and no-claude keep their colour"
    echo "# The current window is left to window-status-current-format so you never lose"
    echo "# track of where you are."
    printf 'set -g window-status-format "#{?#{==:#{@claude_state},input},#[fg=colour231#,bg=colour160#,bold],#{?#{==:#{@claude_state},stall},#[fg=colour232#,bg=colour214#,bold],#{?#{==:#{@claude_state},done},#[fg=colour232#,bg=colour35#,bold],#{?#{==:#{@claude_state},unknown},#[fg=colour250#,bg=colour240],#[fg=white#,bg=colour234]}}}}#I.#W"\n'
  else
    echo "# Tab colours need #{==:...}, which is tmux 3.1+. Window-name glyphs stand in below that."
  fi
  echo
  echo "# C-a L pops csm up over the screen. Digits jump, q closes."
  echo "unbind L"
  if ver_ge 3 2; then
    echo "bind-key L display-popup -E -w 90% -h 80% \"$SELF watch\""
  else
    echo "bind-key L new-window -n csm \"$SELF watch\""
  fi
  echo "$END_MARK"
}

# ── install ─────────────────────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
OKM='  ✓'; WARNM='  ⚠'; FAILM='  ✗'

cmd_install() {
  local check=0; [ "${1:-}" = "--check" ] && check=1
  local bad=0
  chmod 755 "$SELF" 2>/dev/null

  # bash 3.2 evaluates a later word of the same `local` before the earlier assignment lands
  local bindir="$HOME/.local/bin"
  local link="$bindir/csm"
  local cur=''
  [ -L "$link" ] && cur="$(cd "$(dirname "$(readlink "$link")")" && pwd)/$(basename "$(readlink "$link")")"
  if [ "$cur" = "$SELF" ]; then echo "$OKM csm — already linked"
  elif [ "$check" = 1 ]; then echo "$WARNM csm symlink missing"; bad=1
  else
    mkdir -p "$bindir"; rm -f "$link"; ln -s "$SELF" "$link"
    echo "$OKM csm — symlink created: $link"
  fi
  case ":$PATH:" in *":$bindir:"*) ;; *) echo "$WARNM $bindir is not on PATH — add it in your shell config" ;; esac

  if ! command -v jq >/dev/null 2>&1; then
    echo "$FAILM jq not found — the bash edition needs it (the python edition does not)"
    return 1
  fi

  # Hooks: only entries that call csm are touched, everything else is left alone
  local tmpf; tmpf="$(mktemp)"
  [ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
  if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "$FAILM settings.json is not valid JSON — hooks not registered"; rm -f "$tmpf"; return 1
  fi
  local changed='' ev arg want
  cp "$SETTINGS" "$tmpf"
  while read -r ev arg; do
    want="$SELF hook $arg"
    if EV="$ev" jq -e --arg w "$want" \
         '[(.hooks[$ENV.EV]//[])[].hooks[]? | select(.command == $w and .async == true)] | length > 0' \
         "$tmpf" >/dev/null 2>&1; then
      continue                       # already registered
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
  if [ -z "$changed" ]; then echo "$OKM settings.json hooks — up to date"
  elif [ "$check" = 1 ]; then echo "$WARNM hooks missing or stale:$changed"; bad=1
  else cp "$tmpf" "$SETTINGS"; chmod 600 "$SETTINGS"; echo "$OKM settings.json hooks — registered:$changed"; fi
  rm -f "$tmpf" "$tmpf.new" 2>/dev/null

  # ~/.tmux.conf block
  local conf="$HOME/.tmux.conf" block body new
  block="$(cmd_tmux_conf)"
  body="$(cat "$conf" 2>/dev/null || true)"
  # Replace only the marked region (dropping an old-marker block too). awk -v cannot
  # carry a multi-line value ("newline in string"), so this splices with shell expansion.
  new="$body"
  if [ "${new#*$OLD_BEGIN}" != "$new" ] && [ "${new#*$OLD_END}" != "$new" ]; then
    new="${new%%$OLD_BEGIN*}${new#*$OLD_END}"
  fi
  if [ "${new#*$BEGIN_MARK}" != "$new" ] && [ "${new#*$END_MARK}" != "$new" ]; then
    new="${new%%$BEGIN_MARK*}${new#*$END_MARK}"
  fi
  while [ "${new%$'\n'}" != "$new" ]; do new="${new%$'\n'}"; done
  new="${new:+$new$'\n'$'\n'}$block"
  if [ "$new" = "$body" ]; then echo "$OKM .tmux.conf — up to date"
  elif [ "$check" = 1 ]; then echo "$WARNM .tmux.conf block not applied"; bad=1
  else
    [ -s "$conf" ] && cp "$conf" "$conf.csm-bak"
    printf '%s\n' "$new" > "$conf"
    echo "$OKM .tmux.conf — block applied${body:+ (previous file: $conf.csm-bak)}"
    # Only reload when this really is the running user's home. With HOME overridden
    # (sandbox, test) the conf we just wrote is not the one that server reads, and
    # sourcing it would push our settings onto someone else's session.
    local real_home; real_home="$(eval echo "~$(id -un)")"
    if [ "$HOME" = "$real_home" ] && { [ -n "${TMUX:-}" ] || tmux has-session >/dev/null 2>&1; }; then
      tmux source-file "$conf" 2>/dev/null && echo "$OKM tmux config reloaded"
    fi
  fi

  [ "$bad" = 1 ] && { echo "$FAILM some items are not installed"; return 1; }
  echo "$OKM done — new Claude sessions will report their state."
  return 0
}

# ── entry point ─────────────────────────────────────────────────────────
cmd_list() { state_pass 0; render "$ROWS"; }

cmd_watch() {
  if [ ! -t 1 ]; then cmd_list; return 0; fi     # piped (e.g. a Bash tool call): never loop
  local key
  while :; do
    NOW="${CSM_NOW:-$(date +%s)}"
    state_pass 0
    printf '\033[H\033[2J'
    render "$ROWS"
    printf '\n%s\n' "$T_KEYS"
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
  jump)  [ $# -ge 2 ] || { echo "$T_USAGE_JUMP" >&2; exit 1; }
         state_pass 0
         goto_row "$(nth_row "$ROWS" "$2")" || { echo "$T_NONUM$2" >&2; exit 1; } ;;
  next)  state_pass 0
         pick=''
         for want in input stall done; do
           while IFS="$T" read -r p win idx wname st rest; do
             [ "${st:-}" = "$want" ] && { pick="$p$T$win"; break; }
           done <<< "$ROWS"
           [ -n "$pick" ] && break
         done
         [ -n "$pick" ] || { echo "$T_NOSESS" >&2; exit 1; }
         goto_row "$pick" ;;
  watch) cmd_watch ;;
  hook)  shift; cmd_hook "${1:-done}" ;;
  sweep) cmd_sweep ;;
  tmux-conf|conf) cmd_tmux_conf ;;
  install) shift; cmd_install "${1:-}" ;;
  -h|--help|help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: csm.sh [list|jump <#>|next|watch|hook <event>|sweep|tmux-conf|install]" >&2; exit 1 ;;
esac
