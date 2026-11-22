#!/usr/bin/env python3
"""Check the package matrix and the build-only permissions of the CI workflow."""
from pathlib import Path
import re
import sys

import yaml

path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".github/workflows/build.yml")
workflow = yaml.safe_load(path.read_text(encoding="utf-8"))
events = workflow.get("on", workflow.get(True))
jobs = workflow["jobs"]

assert set(events) == {"push", "pull_request", "workflow_dispatch"}, events
assert set(events["push"]["branches"]) == {"main", "feature/**"}, events["push"]
assert set(events["push"]) == {"branches"}, events["push"]
assert workflow["permissions"] == {"contents": "read"}, workflow["permissions"]
assert set(jobs) == {"checks", "packages", "runtime"}, jobs.keys()
assert jobs["runtime"]["needs"] == ["packages"]

packages = jobs["packages"]["strategy"]["matrix"]
assert set(packages["release"]) == {"24.10.3", "25.12.6"}
assert set(packages["target"]) == {"x86/64", "mediatek/filogic"}
assert {item["release"]: item["channel"] for item in packages["include"]} == {
    "24.10.3": "ipk", "25.12.6": "apk",
}
runtime = jobs["runtime"]["strategy"]["matrix"]["include"]
assert {item["release"]: item["channel"] for item in runtime} == {
    "24.10.3": "ipk", "25.12.6": "apk",
}
for job in jobs.values():
    assert not any(value == "write" for value in job.get("permissions", {}).values())
    for step in job["steps"]:
        assert not re.search(r"\bgh\s+release\s+(?:create|upload|edit)\b|\bgit\s+push\b", step.get("run", ""))
        assert "/publish" not in step.get("uses", "")
print("PASS: workflow builds both ABIs and package formats without publishing releases")
