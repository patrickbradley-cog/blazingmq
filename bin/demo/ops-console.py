#!/usr/bin/env python3
"""Staged "SRE ops console" for the perf-regression demo.

A browser-only page (no API) that shows the bmqt::UriParser::parse latency
history written by bench-alert.sh and lets an operator resolve the incident.
It stands in for the proprietary web consoles SREs still click through; the
triage session drives it with computer use, not curl.

Usage: bin/demo/ops-console.py [--port 8099]
State: $BMQ_DEMO_STATE (default ~/.bmq-demo): history.jsonl, incident.json
"""
import argparse
import html
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

STATE = os.path.expanduser(os.environ.get("BMQ_DEMO_STATE", "~/.bmq-demo"))
HISTORY = os.path.join(STATE, "history.jsonl")
INCIDENT = os.path.join(STATE, "incident.json")


def load_history(limit=20):
    try:
        with open(HISTORY) as f:
            rows = [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        rows = []
    return rows[-limit:]


def load_incident():
    try:
        with open(INCIDENT) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"status": "none"}


def save_incident(inc):
    os.makedirs(STATE, exist_ok=True)
    with open(INCIDENT, "w") as f:
        json.dump(inc, f, indent=2)


def chart(rows):
    if not rows:
        return "<p class=muted>No benchmark runs yet.</p>"
    w, h, pad = 720, 220, 30
    top = max(max(r["median_ms"] for r in rows), rows[-1]["baseline_ms"] * 1.6)
    bw = (w - 2 * pad) / len(rows)
    bars = []
    for i, r in enumerate(rows):
        bh = (h - 2 * pad) * r["median_ms"] / top
        x, y = pad + i * bw + 3, h - pad - bh
        color = "#d93025" if r["ratio"] >= r["threshold"] else "#188038"
        bars.append(
            f'<rect x="{x:.0f}" y="{y:.0f}" width="{bw - 6:.0f}" height="{bh:.0f}" fill="{color}">'
            f'<title>{html.escape(r["sha"])} {r["median_ms"]} ms</title></rect>'
            f'<text x="{x + (bw - 6) / 2:.0f}" y="{y - 4:.0f}" font-size="11" text-anchor="middle">{r["median_ms"]:.0f}</text>'
        )
    base = rows[-1]["baseline_ms"]
    ty = h - pad - (h - 2 * pad) * base * rows[-1]["threshold"] / top
    by = h - pad - (h - 2 * pad) * base / top
    return (
        f'<svg width="{w}" height="{h}" role="img" aria-label="parse latency">'
        f'<line x1="{pad}" x2="{w - pad}" y1="{by:.0f}" y2="{by:.0f}" stroke="#5f6368" stroke-dasharray="4"/>'
        f'<text x="{w - pad}" y="{by - 4:.0f}" font-size="11" text-anchor="end">baseline {base} ms</text>'
        f'<line x1="{pad}" x2="{w - pad}" y1="{ty:.0f}" y2="{ty:.0f}" stroke="#d93025" stroke-dasharray="2"/>'
        f'<text x="{w - pad}" y="{ty - 4:.0f}" font-size="11" text-anchor="end" fill="#d93025">alert {rows[-1]["threshold"]}x</text>'
        + "".join(bars)
        + "</svg>"
    )


def page(msg=""):
    rows = load_history()
    inc = load_incident()
    latest = rows[-1] if rows else None
    recovered = bool(latest and latest["ratio"] < latest["threshold"])
    status = inc.get("status", "none")
    badge = {"open": "#d93025", "resolved": "#188038"}.get(status, "#5f6368")
    table = "".join(
        f"<tr><td>{html.escape(r['time'])}</td><td><code>{html.escape(r['sha'])}</code></td>"
        f"<td>{html.escape(r.get('label', ''))}</td><td>{r['median_ms']}</td><td>{r['ratio']}x</td></tr>"
        for r in reversed(rows)
    )
    resolve = ""
    if status == "open":
        dis = "" if recovered else "disabled"
        hint = (
            "Latest run is back under the alert threshold."
            if recovered
            else "Latest run is still above the alert threshold; resolve is locked."
        )
        resolve = (
            f'<form method="post" action="/resolve"><label>Resolution note<br>'
            f'<input name="note" size="60" placeholder="e.g. fix PR #12, 240 ms -> 39 ms"></label><br>'
            f'<button id="resolve" {dis}>Resolve incident</button> <span class=muted>{hint}</span></form>'
        )
    return f"""<!doctype html><html><head><meta charset=utf-8><title>BMQ Ops Console</title>
<style>body{{font:15px system-ui,sans-serif;margin:32px;max-width:820px}}
.badge{{color:#fff;background:{badge};padding:3px 10px;border-radius:12px}}
.muted{{color:#5f6368}} table{{border-collapse:collapse}} td,th{{padding:4px 10px;border-bottom:1px solid #eee;text-align:left}}
button{{font-size:15px;padding:6px 16px;margin-top:8px}} .msg{{background:#e6f4ea;padding:8px}}</style></head><body>
<h1>BlazingMQ Ops Console</h1>
<p class=muted>Service: libbmq / bmqt::Uri &middot; metric: <code>bmqt::UriParser::parse threads=1</code> (100k parses, median)</p>
{f'<p class=msg>{html.escape(msg)}</p>' if msg else ''}
<h2>Incident <span class=badge id=incident-status>{html.escape(status.upper())}</span></h2>
<p>{html.escape(inc.get('title', 'No incident recorded.'))}</p>
{f"<p class=muted>Opened {html.escape(inc['opened'])}</p>" if inc.get('opened') else ''}
{f"<p class=muted>Resolved {html.escape(inc['resolved'])}: {html.escape(inc.get('note', ''))}</p>" if inc.get('resolved') else ''}
{resolve}
<h2>Parse latency, last {len(rows)} runs</h2>{chart(rows)}
<table><tr><th>time (UTC)</th><th>commit</th><th>run</th><th>median ms</th><th>ratio</th></tr>{table}</table>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, body, code=200):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(page() if self.path in ("/", "/index.html") else "not found", 200 if self.path in ("/", "/index.html") else 404)

    def do_POST(self):
        if self.path != "/resolve":
            return self._send("not found", 404)
        n = int(self.headers.get("Content-Length", 0))
        note = parse_qs(self.rfile.read(n).decode()).get("note", [""])[0]
        rows, inc = load_history(), load_incident()
        if inc.get("status") != "open":
            return self._send(page("No open incident."))
        if not rows or rows[-1]["ratio"] >= rows[-1]["threshold"]:
            return self._send(page("Refused: latest run is still regressed."))
        inc.update(status="resolved", resolved=time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime()), note=note)
        save_incident(inc)
        self._send(page("Incident resolved."))

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    port = ap.parse_args().port
    print(f"BMQ ops console on http://localhost:{port} (state: {STATE})")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
