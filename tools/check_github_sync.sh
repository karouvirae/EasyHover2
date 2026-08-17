#!/usr/bin/env bash
# Verify the GitHub remote is fully in sync with local main -- i.e. every EH2 change, plus the
# Suite (easyhover2_suite.lua) and SuiteX (easyhover2_suitex.lua), that exists locally has landed
# on origin. Read-only: it fetches, it never pushes. Useful after a push that happened while GitHub
# was flaky (e.g. the SuiteX drain fix landed during a GitHub browser outage).
#
#   bash tools/check_github_sync.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
BR="${1:-main}"

echo "== fetching origin (read-only) =="
if ! git fetch origin --quiet 2>/dev/null; then
  echo "FAIL: cannot reach GitHub (git fetch failed). Try again once github.com is back for you."
  exit 1
fi

LOCAL="$(git rev-parse "$BR" 2>/dev/null)"
REMOTE="$(git rev-parse "origin/$BR" 2>/dev/null)"
echo "local  $BR: $LOCAL"
echo "remote $BR: $REMOTE"

AHEAD="$(git rev-list --count "origin/$BR..$BR" 2>/dev/null)"
BEHIND="$(git rev-list --count "$BR..origin/$BR" 2>/dev/null)"
DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"

echo ""
echo "unpushed (local ahead):  $AHEAD commit(s)"
[ "$AHEAD" -gt 0 ] && git log --oneline "origin/$BR..$BR"
echo "unpulled (remote ahead): $BEHIND commit(s)"
[ "$BEHIND" -gt 0 ] && git log --oneline "$BR..origin/$BR"
echo "uncommitted working-tree changes: $DIRTY file(s)"

echo ""
echo "== key files present on origin/$BR =="
for f in easyhover2_suite.lua easyhover2_suitex.lua manifest.lua; do
  if git cat-file -e "origin/$BR:$f" 2>/dev/null; then
    # short content hash of the remote copy, so you can eyeball a version match
    H="$(git rev-parse "origin/$BR:$f" | cut -c1-12)"
    echo "  ok   $f  (blob $H)"
  else
    echo "  MISS $f  -- not on origin/$BR"
  fi
done

# Manifest release version (the EH2 'current version' string), from the remote copy.
MV="$(git show "origin/$BR:manifest.lua" 2>/dev/null | grep -oE 'version[^,]*' | head -1)"
[ -n "$MV" ] && echo "  manifest $MV (on origin)"

echo ""
if [ "$LOCAL" = "$REMOTE" ]; then
  echo "RESULT: IN SYNC -- origin/$BR matches local $BR ($LOCAL). All committed EH2 + Suite + SuiteX are on GitHub."
  [ "$DIRTY" -gt 0 ] && echo "        (note: $DIRTY uncommitted local change(s) are NOT on GitHub yet -- commit to publish them.)"
  exit 0
else
  echo "RESULT: OUT OF SYNC -- origin/$BR ($REMOTE) != local $BR ($LOCAL)."
  [ "$AHEAD" -gt 0 ] && echo "        push $AHEAD local commit(s) to publish them."
  [ "$BEHIND" -gt 0 ] && echo "        pull $BEHIND remote commit(s) first."
  exit 1
fi
