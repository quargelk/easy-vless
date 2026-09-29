#!/usr/bin/env python3
"""Event separation of .github/workflows/build.yml (checks job and locally):

  pull request, push to main, workflow_dispatch  full CI: checks, build, the
                                                  whole runtime-tests matrix,
                                                  ubifs; no release
  push of a v* tag                                release pipeline only:
                                                  checks, build, release

The jobs of an event are computed from the workflow itself: the job-level
"if" (startsWith(github.ref, ...) with !, &&, ||) is evaluated for the ref of
the event, and a job whose "needs" did not run is skipped, as on GitHub.

  python3 tests/ci/workflow-events.py [.github/workflows/build.yml]
"""
import re
import sys

import yaml

path = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows/build.yml"
with open(path, encoding="utf-8") as f:
    wf = yaml.safe_load(f)

FAILED = []


def check(ok, msg):
    print(("PASS: " if ok else "FAIL: ") + msg)
    if not ok:
        FAILED.append(msg)


def cond(expr, ref):
    """Evaluate a job-level "if" for github.ref = ref (only the forms used here)."""
    if expr is None:
        return True
    e = str(expr).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", e, re.S)
    if m:
        e = m.group(1).strip()
    e = re.sub(r"startsWith\(\s*github\.ref\s*,\s*'([^']*)'\s*\)",
               lambda m: repr(ref.startswith(m.group(1))), e)
    e = e.replace("&&", " and ").replace("||", " or ")
    e = re.sub(r"!(?!=)", " not ", e)
    if not re.fullmatch(r"[\sA-Za-z()]*", e) or set(re.findall(r"[A-Za-z]+", e)) - {"True", "False", "and", "or", "not"}:
        raise SystemExit("FAIL: unsupported job condition in %s: %r" % (path, expr))
    return bool(eval(e))


def needs(job):
    n = job.get("needs", [])
    return [n] if isinstance(n, str) else list(n)


def matrix_size(job):
    m = (job.get("strategy") or {}).get("matrix")
    if not m:
        return 1
    size = 1
    for k, v in m.items():
        if isinstance(v, list) and k not in ("include", "exclude"):
            size *= len(v)
    return size


jobs = wf["jobs"]


def running(ref):
    run = {}

    def runs(name):
        if name not in run:
            job = jobs[name]
            run[name] = cond(job.get("if"), ref) and all(runs(n) for n in needs(job))
        return run[name]

    return {n: matrix_size(jobs[n]) for n in jobs if runs(n)}


EVENTS = [
    ("pull_request", "refs/pull/1/merge"),
    ("push main", "refs/heads/main"),
    ("workflow_dispatch (main)", "refs/heads/main"),
    ("push tag v*", "refs/tags/v0.0.0"),
]
FULL = {"checks", "build", "runtime-tests", "ubifs"}
RELEASE = {"checks", "build", "release"}

# PyYAML reads the key "on" as True
on = wf.get("on", wf.get(True))
check(isinstance(on, dict) and {"push", "pull_request", "workflow_dispatch"} <= set(on), "triggers: push, pull_request, workflow_dispatch")
push = on.get("push") or {}
pr = on.get("pull_request") or {}
check(push.get("branches") == ["main"] and push.get("tags") == ["v*"], "push: branch main and v* tags")
check(pr.get("paths") == push.get("paths") and bool(pr.get("paths")), "pull_request runs for the same paths as a push to main")

for event, ref in EVENTS:
    r = running(ref)
    print("  %-26s %s" % (event + ":", ", ".join("%s%s" % (n, " (x%d)" % c if c > 1 else "") for n, c in r.items())))
    if event == "push tag v*":
        check(set(r) == RELEASE, "%s: only %s" % (event, ", ".join(sorted(RELEASE))))
    else:
        check(set(r) == FULL, "%s: full CI (%s), no release" % (event, ", ".join(sorted(FULL))))

check(matrix_size(jobs["runtime-tests"]) >= 24, "runtime-tests matrix: %d jobs (6 targets x 4 groups)" % matrix_size(jobs["runtime-tests"]))
check(set(needs(jobs["release"])) == {"checks", "build"}, "release needs only checks and build")
steps = jobs["release"].get("steps", [])
gate = [i for i, s in enumerate(steps) if "full CI run of the tagged commit" in s.get("name", "")]
create = [i for i, s in enumerate(steps) if "gh release create" in s.get("run", "")]
check(bool(gate) and bool(create) and gate[0] < create[0], "release requires a successful full CI run of the tagged commit before the draft is created")
check(bool(create) and "--draft" in steps[create[0]]["run"], "release creates a draft")
writers = [n for n, j in jobs.items() if (j.get("permissions") or {}).get("contents") == "write"]
check(writers == ["release"], "contents: write only in release (%s)" % ", ".join(writers))

print("===== workflow event separation: %s =====" % ("FAILED: %d" % len(FAILED) if FAILED else "ok"))
sys.exit(1 if FAILED else 0)
