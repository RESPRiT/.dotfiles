#!/bin/sh
# PreToolUse(Bash) guard: `cd` is reserved for setting your "homebase" working
# directory and must be a STANDALONE command -- its own Bash call with nothing
# chained (no `&&` `;` `||` `|` `&`, no subshell). A `cd` used to run work
# elsewhere (`cd build && make`) silently changes the persistent shell cwd for
# the rest of the session, which is how an agent loses track of where it is and
# starts resolving relative paths against the wrong directory. Blocking the
# non-solo form forces the durable alternatives (absolute paths, `git -C`,
# `make -C`, a tool's own path arg) and keeps a bare `cd` meaning "this is my
# new homebase".
#
# This BLOCKS (exit 2 + stderr), like protect-settings.sh -- not reminder-only
# like pretool-pr-authoring-reminder.sh.
#
# Detection is best-effort syntactic: a char scanner that respects single/double
# quotes, splits the command into statements on UNQUOTED shell operators
# (`;` `|` `&` `&&` `||` and newline) and on subshell parens, then checks whether
# each statement's command word is `cd`. It is the PREVENTION layer; the
# UserPromptSubmit homebase reporter is the BACKSTOP that catches any drift that
# slips through (a `cd` smuggled via `eval`/`bash -c`, a brace group, a loop
# body), so the scanner does not need to be airtight. Known, accepted misses:
# brace groups `{ cd x; }` and loop bodies `for..do cd..done` are not detected.
#
# Wired via the PreToolUse "Bash" matcher in claude-global/settings.json.

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# Fast path: if the substring `cd` never appears, no `cd` command is possible.
case "$cmd" in
  *cd*) ;;
  *) exit 0 ;;
esac

# Emit "<statement_count> <cd_statement_count>". Whole stdin is slurped into buf
# (re-adding newlines) so multi-line commands are scanned as one unit. Quote
# chars are built with sprintf to avoid embedding quotes in this awk program.
set -- $(printf '%s' "$cmd" | awk '
{ buf = buf (NR > 1 ? "\n" : "") $0 }
END {
  SQ = sprintf("%c", 39); DQ = sprintf("%c", 34)
  n = length(buf); seg = ""; sq = 0; dq = 0; stmts = 0; cds = 0
  for (i = 1; i <= n; i++) {
    c = substr(buf, i, 1); nx = (i < n) ? substr(buf, i + 1, 1) : ""
    if (sq) { if (c == SQ) sq = 0; else seg = seg c; continue }
    if (dq) {
      if (c == "\\") { seg = seg c nx; i++; continue }
      if (c == DQ) dq = 0; else seg = seg c
      continue
    }
    if (c == SQ) { sq = 1; continue }
    if (c == DQ) { dq = 1; continue }
    if (c == "\\") { if (i < n) { seg = seg nx; i++ } continue }
    if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")" || c == "\n") {
      flush(seg); seg = ""
      if ((c == "&" && nx == "&") || (c == "|" && nx == "|")) i++
      continue
    }
    seg = seg c
  }
  flush(seg)
  print stmts, cds
}
function flush(s,   t, w) {
  gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
  if (s == "") return
  stmts++
  t = s
  while (match(t, /^[A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+/)) t = substr(t, RLENGTH + 1)
  while (match(t, /^(sudo|command|builtin|exec|nohup|time)[ \t]+/)) t = substr(t, RLENGTH + 1)
  w = t; sub(/[ \t].*$/, "", w)
  if (w == "cd") cds++
}
')
stmt_count=${1:-0}
cd_count=${2:-0}

# Allow: no cd statement at all, or the ONLY statement is a single cd.
[ "$cd_count" -eq 0 ] && exit 0
[ "$stmt_count" -le 1 ] && [ "$cd_count" -eq 1 ] && exit 0

cat >&2 <<'EOF'
BLOCKED: `cd` must be a standalone command -- its own Bash call with nothing
chained (no `&&`, `;`, `|`, `&`, or subshell). It is reserved for setting your
"homebase" working directory; chaining it (e.g. `cd dir && cmd`) silently moves
the shell for the rest of the session and is how relative paths drift.

To act in another directory WITHOUT changing your homebase, use one of:
  - an absolute path:       cat /abs/path/file        (not: cd dir && cat file)
  - a tool's directory flag: git -C <dir> ...,  make -C <dir>,  ls <dir>,  tar -C <dir>
  - the tool's own path argument

If you genuinely mean to change your homebase, run the `cd` on its own line.
EOF
exit 2
