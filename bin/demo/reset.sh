#!/usr/bin/env bash
# Reset the perf-regression demo: close every open fix PR targeting
# demo/bloomberg-sre and delete its head branch. Never merges anything.
#
# Usage: bin/demo/reset.sh [--yes]
# Needs: gh (authenticated for COG-GTM/blazingmq) or GITHUB_TOKEN + curl.
set -euo pipefail

REPO="${REPO:-COG-GTM/blazingmq}"
BASE="demo/bloomberg-sre"
API="https://api.github.com/repos/${REPO}"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    list() { gh api "repos/${REPO}/pulls?state=open&base=${BASE}&per_page=100" \
        --jq '.[] | "\(.number) \(.head.ref)"'; }
    close() { gh api -X PATCH "repos/${REPO}/pulls/$1" -f state=closed >/dev/null; }
    delbr() { gh api -X DELETE "repos/${REPO}/git/refs/heads/$1" >/dev/null || true; }
elif [ -n "${GITHUB_TOKEN:-}" ]; then
    H=(-H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json")
    list() { curl -fsS "${H[@]}" "${API}/pulls?state=open&base=${BASE}&per_page=100" |
        python3 -c 'import json,sys; [print(p["number"], p["head"]["ref"]) for p in json.load(sys.stdin)]'; }
    close() { curl -fsS "${H[@]}" -X PATCH "${API}/pulls/$1" -d '{"state":"closed"}' >/dev/null; }
    delbr() { curl -fsS "${H[@]}" -X DELETE "${API}/git/refs/heads/$1" >/dev/null || true; }
else
    echo "need an authenticated gh CLI or GITHUB_TOKEN" >&2
    exit 2
fi

prs="$(list)"
if [ -z "$prs" ]; then
    echo "nothing to reset: no open PRs into ${BASE}"
    exit 0
fi
echo "open PRs into ${BASE}:"
echo "$prs" | sed 's/^/  #/'
if [ "${1:-}" != --yes ]; then
    read -r -p "close these PRs and delete their branches? [y/N] " ok
    [ "$ok" = y ] || exit 1
fi
while read -r num ref; do
    [ "$ref" = "$BASE" ] && continue
    close "$num" && echo "closed #${num}"
    delbr "$ref" && echo "deleted branch ${ref}"
done <<<"$prs"
echo "reset done. ${BASE} still carries the planted regression."
