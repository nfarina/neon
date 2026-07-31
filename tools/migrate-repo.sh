#!/bin/zsh
# Relocate the repo from ~/Code/neo to ~/Code/neon (the Neo -> Neon rename),
# carrying Claude Code and Codex session history along. Run it from OUTSIDE
# the repo, AFTER exiting any claude/codex sessions using it:
#
#   cd ~ && zsh ~/Code/neo/tools/migrate-repo.sh
#
# (The script relocates itself along with the repo mid-run; that is safe —
# a same-volume rename keeps the file's inode, and the shell holds it open.)
set -euo pipefail

OLD="/Users/nick/Code/neo"
NEW="/Users/nick/Code/neon"
OLD_KEY="-Users-nick-Code-neo"
NEW_KEY="-Users-nick-Code-neon"
CLAUDE="$HOME/.claude"
CODEX="$HOME/.codex"

# ---------------------------------------------------------------- guards
# Guard against the actual hazard rather than guessing process names:
# any process whose cwd is inside the repo would break when it moves.
if lsof -Fn -d cwd 2>/dev/null | grep -qE "^n$OLD(/|\$)"; then
  echo "error: something is still running inside $OLD:" >&2
  lsof -d cwd 2>/dev/null | grep -E "$OLD(/|\$)" | awk '{print "  " $1 " (pid " $2 ")"}' | sort -u >&2
  echo "Exit those first (this includes any claude session in the repo)." >&2
  exit 1
fi
if [[ -n "$(lsof -t +D "$CLAUDE/projects/$OLD_KEY" 2>/dev/null)" ]]; then
  echo "error: a process has files open under $CLAUDE/projects/$OLD_KEY (live claude session?). Exit it first." >&2
  exit 1
fi
[[ -d "$OLD" ]] || { echo "error: $OLD does not exist (already moved?)" >&2; exit 1; }
[[ -e "$NEW" ]] && { echo "error: $NEW already exists" >&2; exit 1; }

# ---------------------------------------------------------------- backups
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="$HOME/neon-rename-backup-$STAMP"
mkdir -p "$BK"
tar -czf "$BK/claude-projects.tar.gz" -C "$CLAUDE/projects" "./$OLD_KEY"
cp "$HOME/.claude.json" "$BK/claude.json"
cp "$CLAUDE/history.jsonl" "$BK/claude-history.jsonl" 2>/dev/null || true
cp "$CODEX/config.toml" "$BK/codex-config.toml"
cp "$CODEX/state_5.sqlite" "$BK/codex-state_5.sqlite"
echo "backups in $BK"

# ---------------------------------------------------------------- move repo
mv "$OLD" "$NEW"
echo "moved repo -> $NEW"

# ------------------------------------------- move claude project history
mv "$CLAUDE/projects/$OLD_KEY" "$CLAUDE/projects/$NEW_KEY"
echo "moved claude history -> projects/$NEW_KEY"

# ------------------------------------------- patch path strings
# Boundary-aware: the lookahead keeps already-patched ".../neon" untouched,
# so the substitution is idempotent.
PATCH='s{/Users/nick/Code/neo(?![\w-])}{/Users/nick/Code/neon}g'

perl -pi -e "$PATCH" "$CLAUDE/projects/$NEW_KEY"/*.jsonl(N)
mem_files=("$CLAUDE/projects/$NEW_KEY"/memory/*.md(N))
(( ${#mem_files} )) && perl -pi -e "$PATCH" "${mem_files[@]}"
[[ -f "$CLAUDE/history.jsonl" ]] && perl -pi -e "$PATCH" "$CLAUDE/history.jsonl"
for f in "$CLAUDE"/sessions/*.json(N); do
  grep -q "$OLD" "$f" 2>/dev/null && perl -pi -e "$PATCH" "$f" || true
done

# .claude.json: rename the project key, merging if the new key somehow
# already exists (e.g. claude was launched from ~/Code/neon first).
python3 - <<'PY'
import json

path = "/Users/nick/.claude.json"
d = json.load(open(path))
projects = d.get("projects", {})
old = projects.pop("/Users/nick/Code/neo", None)
if old is None:
    print(".claude.json: no old key (already clean)")
else:
    new = projects.get("/Users/nick/Code/neon", {})
    merged = {**old, **new}
    if isinstance(old.get("history"), list) and isinstance(new.get("history"), list):
        seen, combined = set(), []
        for entry in old["history"] + new["history"]:
            key = json.dumps(entry, sort_keys=True)
            if key not in seen:
                seen.add(key)
                combined.append(entry)
        merged["history"] = combined
    projects["/Users/nick/Code/neon"] = merged
    d["projects"] = projects
    json.dump(d, open(path, "w"), indent=2)
    print(".claude.json: project key now /Users/nick/Code/neon")
PY
echo "patched claude metadata"

perl -pi -e "$PATCH" "$CODEX/config.toml"
grep -rl --include='*.jsonl' "$OLD" "$CODEX/sessions" 2>/dev/null | while read -r f; do
  perl -pi -e "$PATCH" "$f"
done
sqlite3 "$CODEX/state_5.sqlite" \
  "UPDATE threads SET cwd = '$NEW' WHERE cwd = '$OLD';"
echo "patched codex metadata"

# ---------------------------------------------------------------- done
echo ""
echo "Neon is lit. Next:"
echo "  cd ~/Code/neon && claude --resume"
echo ""
echo "If anything looks wrong, everything needed to undo is in $BK"
