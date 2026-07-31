#!/bin/zsh
# Final step of the ~/neo -> ~/Code/neo migration: merge the old project key
# in ~/.claude.json into the new one and patch ~/.claude/history.jsonl.
# Run AFTER exiting claude:   cd ~ && zsh ~/Code/neo/tools/finish-migration.sh
set -euo pipefail

if [[ -n "$(lsof -t +D "$HOME/.claude/projects/-Users-nick-Code-neo" 2>/dev/null)" ]]; then
  echo "error: a claude session is still running in the project. Exit it first." >&2
  exit 1
fi

BK="$HOME/neo-migration-backup-final-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
cp "$HOME/.claude.json" "$BK/claude.json"
cp "$HOME/.claude/history.jsonl" "$BK/claude-history.jsonl" 2>/dev/null || true
echo "backups in $BK"

python3 - <<'PY'
import json

path = "/Users/nick/.claude.json"
d = json.load(open(path))
projects = d.get("projects", {})
old = projects.pop("/Users/nick/neo", None)
if old is None:
    print(".claude.json already clean — nothing to merge")
else:
    new = projects.get("/Users/nick/Code/neo", {})
    # Old key holds the accumulated state (trust, approvals, prompt history);
    # the new key was freshly created on first resume — its values win only
    # where both exist, and the per-project prompt histories are concatenated.
    merged = {**old, **new}
    if isinstance(old.get("history"), list) and isinstance(new.get("history"), list):
        seen, combined = set(), []
        for entry in old["history"] + new["history"]:
            key = json.dumps(entry, sort_keys=True)
            if key not in seen:
                seen.add(key)
                combined.append(entry)
        merged["history"] = combined
    projects["/Users/nick/Code/neo"] = merged
    d["projects"] = projects
    json.dump(d, open(path, "w"), indent=2)
    print("merged old project key into /Users/nick/Code/neo")
PY

if [[ -f "$HOME/.claude/history.jsonl" ]]; then
  perl -pi -e 's{/Users/nick/neo(?![\w-])}{/Users/nick/Code/neo}g' "$HOME/.claude/history.jsonl"
  echo "patched history.jsonl"
fi

echo "done — start claude normally from ~/Code/neo"
