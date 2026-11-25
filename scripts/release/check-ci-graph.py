#!/usr/bin/env python3
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Checks ci.yml's job graph, read as JSON on stdin (yq -o=json): the version job needs every check
# job, so a commit whose checks fail is never tagged, and every job that publishes needs the version
# job and runs only when it pushed a tag, so a run publishes only the tag it pushed itself. The
# publishing jobs are named below; every other job except version is a check job, so no other job may
# depend on version. The macos-package check job must run the full macOS package suite, an
# unfiltered `swift test --package-path SSMConnectKit`, on a macOS runner. Exits 1 naming each violation.
import json, re, sys

jobs = json.load(sys.stdin)["jobs"]
PUBLISHING = {"release", "macos", "macos-latest", "windows", "winget", "linux"}
def needs(name):
    value = jobs[name].get("needs", [])
    return [value] if isinstance(value, str) else value
def depends_on_version(name, seen=()):
    return any(n == "version" or (n not in seen and depends_on_version(n, seen + (name,))) for n in needs(name))

errors = []
if "version" not in jobs:
    errors.append("no version job")
else:
    if "vhco-pro/version-workflow/" not in jobs["version"].get("uses", ""):
        errors.append("the version job does not call vhco-pro/version-workflow")
    # Any if on version (always(), !failure(), ...) could let it run after a check failed.
    if "if" in jobs["version"]:
        errors.append("the version job has an if")
    checks = [n for n in jobs if n != "version" and n not in PUBLISHING]
    for n in sorted(PUBLISHING - set(jobs)):
        errors.append(f"the publishing job {n} is missing")
    for n in checks:
        if depends_on_version(n):
            errors.append(f"{n} depends on version but is not a publishing job")
    for n in checks:
        if n not in needs("version"):
            errors.append(f"version does not need the check job {n}")
        # A check that may fail without failing would let version tag a commit it did not pass.
        if str(jobs[n].get("continue-on-error", "false")).lower() != "false":
            errors.append(f"the check job {n} sets continue-on-error")
        for step in jobs[n].get("steps", []):
            if str(step.get("continue-on-error", "false")).lower() != "false":
                errors.append(f"a step of the check job {n} sets continue-on-error")
            # A run step that can be skipped lets the job pass without its check; only the
            # toolchain setup actions are conditional.
            if "run" in step and "if" in step:
                errors.append(f"a run step of the check job {n} has an if")
    for n in jobs:
        if n == "version" or n in checks:
            continue
        condition = " ".join(str(jobs[n].get("if", "")).split())
        if "version" not in needs(n):
            errors.append(f"{n} does not need version")
        # The tagged expression alone, or narrowed with &&; never widened with ||.
        gate = "needs.version.outputs.tagged == 'true'"
        if not (condition == gate or condition.startswith(gate + " && ")) or "||" in condition:
            errors.append(f"{n} does not run only on version's tagged output")
        if any(f in condition for f in ("always()", "failure()", "cancelled()")):
            errors.append(f"{n} can run when a job it needs did not succeed")
full_suite = re.compile(r"^\s*swift test --package-path SSMConnectKit\s*$", re.M)
macos = jobs.get("macos-package")
if macos is None:
    errors.append("no macos-package check job")
else:
    if not str(macos.get("runs-on", "")).startswith("macos-"):
        errors.append("macos-package does not run on a macOS runner")
    if not any(full_suite.search(str(step.get("run", ""))) for step in macos.get("steps", [])):
        errors.append("macos-package does not run the full suite (swift test --package-path SSMConnectKit, unfiltered)")
for e in errors:
    print(f"FAIL {e}")
sys.exit(1 if errors else 0)
