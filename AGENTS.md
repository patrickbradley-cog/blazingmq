# AGENTS.md

## Build and test

- Build (deps + everything, ~9 min clean, incremental after): `bin/build-ubuntu.sh`
- Rebuild one test driver: `cmake --build build/blazingmq --target bmqt_uri.t`
- Unit tests: `(cd build/blazingmq && ctest -R bmqt -j8)`
- URI benchmark: `build/blazingmq/tests/bmqt_uri.t -1`
- Commit messages must contain `feature` or `bug`.

## Perf regression triage

The runbook for a session started by a `:rotating_light: PERF REGRESSION bmqt::UriParser::parse`
alert in #oncall-alerts (C0BNWUGCWBS).

> **Demo note.** Branch `demo/bloomberg-sre` carries a *deliberately simulated*
> regression, modelled on upstream BlazingMQ PR #1011 ("Perf[bmqt::Uri]: remove regex
> dependency for Uri parsing", 5.7x faster). Upstream BlazingMQ is not affected.
> Say this in the RCA and in the PR text. **Never merge the fix PR** and never push to
> `demo/bloomberg-sre` directly; the regression must stay reusable.

Every update goes in the **alert's Slack thread** (reply to the alert message, not the channel).
Keep each post short: one heading line, then 3-6 bullets.

1. **Acknowledge** (within 1 min). Post: `:eyes: Ack — triaging. Plan: bisect <range> with the
   URI benchmark, then RCA.` Copy the range from the alert's *Commit range* field.
2. **Prepare.** `git fetch origin && git checkout demo/bloomberg-sre && git reset --hard origin/demo/bloomberg-sre`.
   The build dir is prebuilt. Confirm the alert with `bin/demo/bench-alert.sh --check`
   (prints the median vs. baseline and exits 1 when regressed).
3. **Correlate — bisect.** The demo scripts must live outside the tree while bisecting:
   ```
   cp bin/demo/bench-alert.sh bin/demo/baseline.json /tmp/
   git bisect start HEAD <last_good_sha>
   git bisect run /tmp/bench-alert.sh --check --runs 3
   git bisect log > /tmp/bisect.log; git bisect reset
   ```
   Post: `:mag: Bisected to <short sha> "<subject>" (<author>)` plus the good/bad medians.
4. **Investigate + RCA.** Read the culprit diff (`git show <sha>`). Post an RCA with exactly:
   - *Culprit:* commit sha + subject.
   - *Root cause:* what the code does on the hot path and why it is slow.
   - *Blast radius:* `bmqt::UriParser::parse` runs for every queue URI parsed by every BlazingMQ
     client (`bmqa::Session::openQueue*`, `bmqt::Uri` constructors) **and** every broker
     (open-queue requests, domain/cluster routing). All clients and brokers built from this
     branch pay the cost on each parse.
   - *Evidence:* baseline vs. current medians (ms) and the ratio; good vs. bad bisect medians.
   - *Note:* simulated regression modelled on upstream PR #1011.
5. **Test the hypothesis.** Don't recommend on bisect alone. Revert only the culprit in the
   working tree and re-run the gate, then put the tree back:
   ```
   git revert --no-commit <sha>
   BENCH_LABEL="hypothesis: revert <short sha>" bin/demo/bench-alert.sh --check --runs 3
   git revert --abort
   ```
   Post `:test_tube: Hypothesis confirmed: reverting <short sha> alone takes parse from <bad> ms
   to <reverted> ms (<ratio>x baseline).` If the ratio is still >= 1.5x, post *refuted*, go
   back to step 4 and look at the other commits in the range.
6. **Recommend.** Post the proposed fix (one or two bullets) and the regression guard you will add,
   then end with: `Reply **approve** in this thread to open the fix PR.`
7. **STOP.** Do not edit code or open a PR until a human replies in the thread with a message
   containing `approve`. Anything else is a question: answer it in the thread and keep waiting.
8. **Remediate** (after approval). Branch `devin/<epoch>-fix-uri-parse-regression` off
   `demo/bloomberg-sre`. Make the fix, plus a regression guard:
   - a unit test in `src/groups/bmq/bmqt/bmqt_uri.t.cpp` that fails if parsing a valid URI
     touches the regex path / allocates from the default allocator;
   - a coarse benchmark threshold check (`bin/demo/bench-alert.sh --check`, fails at >= 1.5x
     the committed baseline) and mention it in the PR as the perf gate.
9. **Verify.** `cmake --build build/blazingmq --target bmqt_uri.t` then
   `(cd build/blazingmq && ctest -R bmqt -j8)` and
   `BENCH_LABEL="fix PR" bin/demo/bench-alert.sh --check` (5 runs, median). Record
   before/after medians.
10. **PR.** Open a PR **into `demo/bloomberg-sre`** (not `main`). Title starts with
   `Fix[bmqt::Uri]: bug -`. Body: the alert, the bisect result, the RCA, before/after table,
   test output summary, and the simulated-regression note. Do not merge.
11. **Review.** Run Devin Review on the PR and wait for it to finish.
12. **Confirm recovery in the ops console (computer use).** The ops console is a browser-only
    page with no API, like the vendor consoles SREs still click through. Start it with
    `bin/demo/ops-console.py &` and open http://localhost:8099 **in the browser** (do not curl
    it). Check the latest bar is green and under the alert line, type the PR link and
    before/after medians into *Resolution note*, click **Resolve incident**, and confirm the
    badge reads RESOLVED. The button stays locked while the latest run is still regressed.
    Screenshot the page and attach it to the thread.
13. **Close the loop.** Post in the thread: PR link, before/after medians + ratio, ops-console screenshot,
    `ctest -R bmqt` result, Devin Review status. Then stop.

## Pre-merge perf check (proactive)

The runbook for a session started by a PR opened into `demo/proactive-base`. The goal is to catch
a risky change before it merges, so it never pages anyone. `demo/proactive-base` is
`demo/bloomberg-sre` with the simulated regression reverted (the healthy baseline). The demo PR
from `bin/demo/open-risky-change.sh` re-applies that regression. Same demo note: simulated,
modelled on upstream PR #1011. **Never merge these PRs.**

1. Check out the PR head, then `BENCH_LABEL="PR #<n> head" bin/demo/bench-alert.sh --check --runs 3`.
   Then check out the base branch and run the same command with `BENCH_LABEL="PR #<n> base"`.
2. If the head ratio is >= 1.5x, read the PR diff and name the line(s) on the hot path that cost
   the time (here: the regex cross-check in `UriParser::parse`). Blast radius as in the triage
   runbook: every client and broker that parses a queue URI.
3. Comment on the PR: a verdict line (`:no_entry: Perf gate: blocks merge` or
   `:white_check_mark: Perf gate: no impact`), a base vs. head table (median ms, ratio), the
   hot-path lines, and a suggested change. Do not push to the PR branch.
4. If it blocks, post once in #oncall-alerts (C0BNWUGCWBS):
   `:warning: PRE-MERGE PERF RISK on <PR link>: parse <base> ms -> <head> ms (<ratio>x). Caught before merge, nothing is paged.`
   Never put the words `PERF REGRESSION` in this post (they start the triage Automation).
5. Run Devin Review on the PR, then stop.
