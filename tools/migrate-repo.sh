#!/bin/zsh
# Relocate the Neo repo from ~/neo to ~/Code/neo, carrying Claude Code and
# Codex session history along. Run this AFTER exiting any Claude/Codex
# sessions that are using ~/neo. Run it from OUTSIDE the repo (your shell's
# cwd must not be inside ~/neo, or the safety guard will flag your own shell):
#
#   cd ~ && zsh ~/neo/tools/migrate-repo.sh
#
# (The script relocates itself along with the repo mid-run; that is safe —
# a same-volume rename keeps the file's inode, and the shell holds it open.)
set -euo pipefail

OLD="/Users/nick/neo"
NEW="/Users/nick/Code/neo"
OLD_KEY="-Users-nick-neo"
NEW_KEY="-Users-nick-Code-neo"
CLAUDE="$HOME/.claude"
CODEX="$HOME/.codex"

# ---------------------------------------------------------------- guards
# Guard against the actual hazard rather than guessing process names:
# any process whose cwd is inside the repo (a live claude/codex session,
# an editor, a stray shell) would break when the directory moves.
if lsof -Fn -d cwd 2>/dev/null | grep -qE "^n$OLD(/|\$)"; then
  echo "error: something is still running inside $OLD:" >&2
  lsof -d cwd 2>/dev/null | grep -E "$OLD(/|\$)" | awk '{print "  " $1 " (pid " $2 ")"}' | sort -u >&2
  echo "Exit those first (this includes any claude session in the repo)." >&2
  exit 1
fi
# Belt and suspenders: a claude session writing this project's transcripts.
if [[ -n "$(lsof -t +D "$CLAUDE/projects/$OLD_KEY" 2>/dev/null)" ]]; then
  echo "error: a process has files open under $CLAUDE/projects/$OLD_KEY (live claude session?). Exit it first." >&2
  exit 1
fi
[[ -d "$OLD" ]] || { echo "error: $OLD does not exist (already moved?)" >&2; exit 1; }
[[ -e "$NEW" ]] && { echo "error: $NEW already exists" >&2; exit 1; }

# ---------------------------------------------------------------- backups
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$HOME/neo-migration-backup-$STAMP"
mkdir -p "$BK"
# "./" prefix stops tar parsing the leading-dash dirname as bundled options
tar -czf "$BK/claude-projects-neo.tar.gz" -C "$CLAUDE/projects" "./$OLD_KEY"
cp "$HOME/.claude.json" "$BK/claude.json"
cp "$CLAUDE/history.jsonl" "$BK/claude-history.jsonl" 2>/dev/null || true
cp "$CODEX/config.toml" "$BK/codex-config.toml"
cp "$CODEX/state_5.sqlite" "$BK/codex-state_5.sqlite"
echo "backups in $BK"

# ---------------------------------------------------------------- move repo
mkdir -p "$HOME/Code"
mv "$OLD" "$NEW"
echo "moved repo -> $NEW"

# ------------------------------------------- move claude project history
mv "$CLAUDE/projects/$OLD_KEY" "$CLAUDE/projects/$NEW_KEY"
echo "moved claude history -> projects/$NEW_KEY"

# ------------------------------------------- patch path strings
# Boundary-aware: never touches /Users/nick/neon or /Users/nick/neo-x.
PATCH='s{/Users/nick/neo(?![\w-])}{/Users/nick/Code/neo}g'

perl -pi -e "$PATCH" "$CLAUDE/projects/$NEW_KEY"/*.jsonl(N)
# guard the glob: perl -pi with zero file args blocks forever reading stdin
mem_files=("$CLAUDE/projects/$NEW_KEY"/memory/*.md(N))
(( ${#mem_files} )) && perl -pi -e "$PATCH" "${mem_files[@]}"
perl -pi -e "$PATCH" "$HOME/.claude.json"
[[ -f "$CLAUDE/history.jsonl" ]] && perl -pi -e "$PATCH" "$CLAUDE/history.jsonl"
for f in "$CLAUDE"/sessions/*.json(N); do
  grep -q "$OLD" "$f" 2>/dev/null && perl -pi -e "$PATCH" "$f" || true
done
echo "patched claude metadata"

perl -pi -e "$PATCH" "$CODEX/config.toml"
grep -rl --include='*.jsonl' "$OLD" "$CODEX/sessions" 2>/dev/null | while read -r f; do
  perl -pi -e "$PATCH" "$f"
done
sqlite3 "$CODEX/state_5.sqlite" \
  "UPDATE threads SET cwd = '$NEW' WHERE cwd = '$OLD';"
echo "patched codex metadata ($(sqlite3 "$CODEX/state_5.sqlite" \
  "SELECT count(*) FROM threads WHERE cwd = '$NEW';") threads)"

# ---------------------------------------------------------------- done
echo ""
echo "Done. Next:"
echo "  cd ~/Code/neo && claude --resume   # pick up where you left off"
echo "  codex resume                        # codex threads follow too"
echo ""
echo "If anything looks wrong, everything needed to undo is in $BK"
