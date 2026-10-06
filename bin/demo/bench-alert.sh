#!/usr/bin/env bash
# Perf-regression alert for bmqt::UriParser::parse (demo tooling).
#
# Runs the bmqt_uri benchmark N times, takes the median of
# "bmqt::UriParser::parse threads=1", compares it with bin/demo/baseline.json
# and, if the ratio is >= the threshold, posts a Block Kit card to Slack.
#
# Usage: bin/demo/bench-alert.sh [--check] [--dry-run] [--runs N]
#   --check    exit 1 on regression, never post (use as a CI/PR guard)
#   --dry-run  print the Slack payload instead of posting
#   --runs N   number of benchmark runs (default 5)
#
# Env: BUILD_DIR (default: <repo>/build/blazingmq), REBUILD=0 to skip rebuild
#      SLACK_ONCALL_BOT_TOKEN or COG_GTM_DEMO_SLACK_BOT_TOKEN (first that can post)
#      SLACK_CHANNEL (default: C0BNWUGCWBS, #oncall-alerts)
set -euo pipefail

# Works from a copy outside the tree (e.g. /tmp during `git bisect run`):
# the repo is taken from the current directory, the baseline from next to
# this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
BASELINE_FILE="${BASELINE_FILE:-${SCRIPT_DIR}/baseline.json}"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build/blazingmq}"
BENCH="${BUILD_DIR}/tests/bmqt_uri.t"
SLACK_CHANNEL="${SLACK_CHANNEL:-C0BNWUGCWBS}"
METRIC="bmqt::UriParser::parse threads=1"
RUNS=5
MODE=post

while [ $# -gt 0 ]; do
    case "$1" in
    --check) MODE=check ;;
    --dry-run) MODE=dry-run ;;
    --runs) RUNS="$2"; shift ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

json_get() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$BASELINE_FILE" "$1"; }

BASELINE_MS="$(json_get parse_threads1_ms)"
THRESHOLD="$(json_get alert_ratio)"
LAST_GOOD_SHA="$(json_get last_good_sha)"

if [ ! -x "$BENCH" ] || [ "${REBUILD:-1}" = 1 ]; then
    echo ">> building bmqt_uri.t" >&2
    cmake --build "$BUILD_DIR" --target bmqt_uri.t >/dev/null
fi

samples=()
for i in $(seq 1 "$RUNS"); do
    ms="$("$BENCH" -1 --benchmark_filter='parse threads=1/' 2>&1 |
        python3 -c '
import re, sys
for line in sys.stdin:
    m = re.match(r"bmqt::UriParser::parse threads=1/\S*\s+([\d.]+) (ns|us|ms|s)\b", line)
    if m:
        scale = {"ns": 1e-6, "us": 1e-3, "ms": 1.0, "s": 1e3}[m.group(2)]
        print("%.2f" % (float(m.group(1)) * scale))
        break
')"
    [ -n "$ms" ] || { echo "benchmark produced no parse threads=1 result" >&2; exit 4; }
    echo ">> run $i/$RUNS: ${ms} ms" >&2
    samples+=("$ms")
done

read -r MEDIAN_MS RATIO < <(python3 -c '
import statistics, sys
s = [float(x) for x in sys.argv[2:]]
m = statistics.median(s)
print("%.1f %.2f" % (m, m / float(sys.argv[1])))
' "$BASELINE_MS" "${samples[@]}")

REGRESSED="$(python3 -c 'import sys; print(int(float(sys.argv[1]) >= float(sys.argv[2])))' "$RATIO" "$THRESHOLD")"
echo "${METRIC}: median ${MEDIAN_MS} ms vs baseline ${BASELINE_MS} ms (${RATIO}x, threshold ${THRESHOLD}x)"

if [ "$REGRESSED" != 1 ]; then
    echo "OK: no regression"
    exit 0
fi
if [ "$MODE" = check ]; then
    echo "FAIL: parse is ${RATIO}x slower than baseline (threshold ${THRESHOLD}x)"
    exit 1
fi

BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --short=10 HEAD)"
RANGE="${LAST_GOOD_SHA:0:10}..${HEAD_SHA}"
HOST="$(hostname)"

PAYLOAD="$(python3 - "$SLACK_CHANNEL" "$METRIC" "$BASELINE_MS" "$MEDIAN_MS" "$RATIO" "$BRANCH" "$RANGE" "$HOST" "$RUNS" <<'PY'
import json, sys
channel, metric, base, cur, ratio, branch, rng, host, runs = sys.argv[1:]
title = ":rotating_light: PERF REGRESSION bmqt::UriParser::parse"
fields = [
    ("Service", "BlazingMQ client/broker library (`libbmq`, `bmqt::Uri`)"),
    ("Metric", "`%s` (100k parses, median of %s runs)" % (metric, runs)),
    ("Baseline vs current", "%s ms -> *%s ms* (*%sx slower*)" % (base, cur, ratio)),
    ("Branch", "`%s`" % branch),
    ("Commit range", "`%s`" % rng),
    ("Host", "`%s`" % host),
]
print(json.dumps({
    "channel": channel,
    "text": "%s: %s ms -> %s ms (%sx) on %s (%s)" % (title, base, cur, ratio, branch, rng),
    "blocks": [
        {"type": "header", "text": {"type": "plain_text", "text": title, "emoji": True}},
        {"type": "section", "fields": [{"type": "mrkdwn", "text": "*%s*\n%s" % f} for f in fields]},
        {"type": "context", "elements": [{"type": "mrkdwn", "text": "Source: `bin/demo/bench-alert.sh` | runbook: `AGENTS.md` > Perf regression triage"}]},
    ],
}))
PY
)"

if [ "$MODE" = dry-run ]; then
    echo "$PAYLOAD"
    exit 0
fi

for var in SLACK_ONCALL_BOT_TOKEN COG_GTM_DEMO_SLACK_BOT_TOKEN; do
    token="${!var:-}"
    [ -n "$token" ] || continue
    resp="$(curl -sS -X POST https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer ${token}" \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data "$PAYLOAD")"
    if python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("ok") else 1)' "$resp"; then
        ts="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["ts"])' "$resp")"
        echo "ALERT POSTED to ${SLACK_CHANNEL} via ${var} (ts=${ts})"
        exit 0
    fi
    err="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("error"))' "$resp")"
    echo "${var} could not post: ${err}" >&2
done
echo "ERROR: no Slack token could post to ${SLACK_CHANNEL}" >&2
exit 3
