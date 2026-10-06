#!/usr/bin/env bash
# Proactive demo: push a "risky change" branch that re-applies the simulated
# URI-parse regression (modelled on upstream PR #1011) on top of the healthy
# demo/proactive-base, ready for a PR into demo/proactive-base. Opening that PR
# starts the pre-merge perf check (AGENTS.md > Pre-merge perf check).
#
# Usage: bin/demo/open-risky-change.sh [--pr]
#   --pr   also open the PR (needs gh or GITHUB_TOKEN); otherwise open it in the UI
set -euo pipefail

REPO="${REPO:-patrickbradley-cog/blazingmq}"
REMOTE="${REMOTE:-origin}"
BASE="demo/proactive-base"
RISKY_SHA="${RISKY_SHA:-693def762d4959308d442f41b13b019526aa14ea}"
BRANCH="demo/risky-uri-check-$(date +%s)"
TITLE="Feat[bmqt::Uri]: feature - cross-check parsed URIs against canonical grammar"

git fetch -q "$REMOTE" "$BASE"
start="$(git rev-parse --abbrev-ref HEAD)"
git switch -q -c "$BRANCH" "$REMOTE/$BASE"
git cherry-pick -x "$RISKY_SHA" >/dev/null
git push -q -u "$REMOTE" "$BRANCH"
git switch -q "$start"
echo "pushed ${BRANCH} (re-applies ${RISKY_SHA:0:10} onto ${BASE})"

if [ "${1:-}" = --pr ]; then
    body="Adds a canonical-grammar regex cross-check to \`bmqt::UriParser::parse\`. (Demo: simulated risky change, modelled on upstream PR #1011. Do not merge.)"
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        gh pr create -R "$REPO" -B "$BASE" -H "$BRANCH" -t "$TITLE" -b "$body"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        python3 - "$REPO" "$BASE" "$BRANCH" "$TITLE" "$body" <<'PY'
import json, os, sys, urllib.request
repo, base, head, title, body = sys.argv[1:]
req = urllib.request.Request(f"https://api.github.com/repos/{repo}/pulls", method="POST",
    data=json.dumps({"title": title, "head": head, "base": base, "body": body}).encode(),
    headers={"Authorization": "Bearer " + os.environ["GITHUB_TOKEN"], "Accept": "application/vnd.github+json"})
print(json.load(urllib.request.urlopen(req))["html_url"])
PY
    else
        echo "no gh/GITHUB_TOKEN: open the PR ${BRANCH} -> ${BASE} in the GitHub UI" >&2
    fi
else
    echo "open a PR: https://github.com/${REPO}/compare/${BASE}...${BRANCH}"
fi
