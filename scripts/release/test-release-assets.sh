#!/usr/bin/env bash
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# Tests release-assets.sh against a fake gh that keeps releases in a JSON file: the release is
# created once without the latest mark, a rerun uploads only missing assets and never replaces one,
# and mark-latest converges on the newest release with a macOS ZIP whatever order jobs finish in.
# It also checks ci.yml's job graph with check-ci-graph.py.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
state_path, log_path = os.environ["FAKE_GH_STATE"], os.environ["FAKE_GH_LOG"]
state = json.load(open(state_path))
args = sys.argv[1:]
open(log_path, "a").write(" ".join(args) + "\n")
def find(tag): return next((r for r in state["releases"] if r["tag_name"] == tag), None)
def save(): json.dump(state, open(state_path, "w"))
if args[:2] == ["release", "view"]:
    release = find(args[2])
    if release is None: sys.exit(1)
    if "--json" in args: print("\n".join(a["name"] for a in release["assets"]))
elif args[:2] == ["release", "create"]:
    assert "--latest=false" in args, "a release must be created without the latest mark"
    state["releases"].append({"tag_name": args[2], "draft": False, "prerelease": "--prerelease" in args, "assets": []}); save()
elif args[:2] == ["release", "upload"]:
    assert "--clobber" not in args, "a published asset must never be replaced"
    names = [a["name"] for a in find(args[2])["assets"]]
    name = os.path.basename(args[3])
    if name in names: sys.exit("asset already exists")
    find(args[2])["assets"].append({"name": name}); save()
elif args[:2] == ["release", "download"]:
    name = args[args.index("--pattern") + 1]
    directory = args[args.index("--dir") + 1]
    assert any(a["name"] == name for a in find(args[2])["assets"]), "download of an unpublished asset"
    open(os.path.join(directory, name), "w").write("published " + name)
elif args[:2] == ["release", "edit"]:
    assert "--latest" in args; state["latest"] = args[2]; save()
elif args[0] == "api" and args[-1].endswith("/releases/latest") or (args[0] == "api" and "releases/latest" in " ".join(args)):
    if not state.get("latest"): sys.exit(1)
    print(state["latest"])
elif args[0] == "api":
    print(json.dumps(state["releases"]))
else:
    sys.exit("unexpected gh call: " + " ".join(args))
PY
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" GITHUB_REPOSITORY=vhco-pro/ssm-connect GITHUB_SHA=abc123
export FAKE_GH_STATE="$work/state.json" FAKE_GH_LOG="$work/gh.log"
script="$here/release-assets.sh"
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
state() { echo "$1" > "$FAKE_GH_STATE"; : > "$FAKE_GH_LOG"; }
release() { echo "{\"tag_name\":\"$1\",\"draft\":false,\"prerelease\":${3:-false},\"assets\":[$2]}"; }
zip() { echo "{\"name\":\"SSMConnect-${1#v}.zip\"}"; }
msi() { echo "{\"name\":\"SSMConnect-${1#v}-x64.msi\"}"; }

# The release is created first, once, without the latest mark; a test tag is a prerelease.
state '{"releases":[]}'
"$script" ensure-release v1.0.0 "SSM Connect 1.0.0" >/dev/null
"$script" ensure-release v1.0.0 "SSM Connect 1.0.0" >/dev/null
check "ensure-release creates the release once" '[ "$(grep -c "release create" "$FAKE_GH_LOG")" = 1 ]'
check "the release is created without the latest mark" 'grep -q -- "--latest=false" "$FAKE_GH_LOG"'
"$script" ensure-release v0.0.0-test.1 "test" --prerelease >/dev/null
check "a test tag is created as a prerelease" 'jq -e ".releases[1].prerelease" "$FAKE_GH_STATE" >/dev/null'

# Platform jobs upload independently; a rerun uploads only what is missing and replaces nothing.
touch "$work/SSMConnect-1.0.0-x64.msi" "$work/SSMConnect-1.0.0-x64.msi.sha256" "$work/SSMConnect-1.0.0.zip"
"$script" upload-missing v1.0.0 "$work/SSMConnect-1.0.0-x64.msi" >/dev/null
"$script" upload-missing v1.0.0 "$work/SSMConnect-1.0.0.zip" >/dev/null
: > "$FAKE_GH_LOG"
"$script" upload-missing v1.0.0 "$work/SSMConnect-1.0.0-x64.msi" "$work/SSMConnect-1.0.0-x64.msi.sha256" >/dev/null
check "a rerun uploads only the missing asset" '[ "$(grep -c "release upload" "$FAKE_GH_LOG")" = 1 ] && grep -q "msi.sha256" "$FAKE_GH_LOG"'
check "both platforms' assets are on the release" '[ "$(jq ".releases[0].assets | length" "$FAKE_GH_STATE")" = 3 ]'

# A rerun job whose artifact is already published continues with the published file, so its
# checksum and manifest describe what users download, not the rebuild.
echo "rebuilt" > "$work/SSMConnect-1.0.0-x64.msi"
reused="$("$script" reuse-published v1.0.0 "$work/SSMConnect-1.0.0-x64.msi" | tail -1)"
check "a rerun uses the published MSI in place of its rebuild" '[ "$reused" = reused=true ] && [ "$(cat "$work/SSMConnect-1.0.0-x64.msi")" = "published SSMConnect-1.0.0-x64.msi" ]'
touch "$work/SSMConnect-2.0.0-x64.msi"
check "a first build keeps its own MSI" '[ "$("$script" reuse-published v1.0.0 "$work/SSMConnect-2.0.0-x64.msi" | tail -1)" = reused=false ]'

# mark-latest picks the newest non-prerelease release with a macOS ZIP.
state "{\"releases\":[$(release v1.2.0 "$(zip v1.2.0)"),$(release v1.3.0 "$(zip v1.3.0),$(msi v1.3.0)"),$(release v1.4.0 "$(msi v1.4.0)"),$(release v1.5.0-test.1 "$(zip v1.5.0-test.1)" true)],\"latest\":\"v1.2.0\"}"
"$script" mark-latest >/dev/null
check "mark-latest marks the newest release with a ZIP, skipping a Windows-only one and a prerelease" '[ "$(jq -r .latest "$FAKE_GH_STATE")" = v1.3.0 ]'
: > "$FAKE_GH_LOG"
"$script" mark-latest >/dev/null
check "mark-latest changes nothing once the right release is latest" '! grep -q "release edit" "$FAKE_GH_LOG"'

# A late older macOS build never displaces a newer one.
state "{\"releases\":[$(release v1.3.0 "$(zip v1.3.0)"),$(release v1.2.1 "$(zip v1.2.1)")],\"latest\":\"v1.3.0\"}"
"$script" mark-latest >/dev/null
check "a late older ZIP leaves the newer release latest" '[ "$(jq -r .latest "$FAKE_GH_STATE")" = v1.3.0 ] && ! grep -q "release edit" "$FAKE_GH_LOG"'

# Versions compare numerically, and a newer ZIP that lost its turn is still marked by any later run.
state "{\"releases\":[$(release v1.9.0 "$(zip v1.9.0)"),$(release v1.10.0 "$(zip v1.10.0)"),$(release v1.8.0 "$(zip v1.8.0)")],\"latest\":\"v1.8.0\"}"
"$script" mark-latest >/dev/null
check "v1.10.0 is newer than v1.9.0, whichever run marks it" '[ "$(jq -r .latest "$FAKE_GH_STATE")" = v1.10.0 ]'

state '{"releases":[]}'
check "mark-latest with no ZIP anywhere changes nothing" '"$script" mark-latest | grep -q "No release has a macOS ZIP" && ! grep -q "release edit" "$FAKE_GH_LOG"'

# ci.yml's graph: the version job needs every check, and every publishing job needs it and runs only
# when it pushed a tag. The check must also catch each of those being removed.
graph() { yq -o=json "$1" | python3 "$here/check-ci-graph.py" >/dev/null; }
ci="$here/../../.github/workflows/ci.yml"
check "ci.yml's version job needs every check and gates every publishing job" 'graph "$ci"'
yq '.jobs.version.needs -= ["helper"]' "$ci" > "$work/no-check.yml"
check "a version job that skips a check fails the graph check" '! graph "$work/no-check.yml"'
yq '.jobs.macos.needs -= ["version"]' "$ci" > "$work/no-needs.yml"
check "a platform job that does not need version fails the graph check" '! graph "$work/no-needs.yml"'
yq 'del(.jobs.linux.if)' "$ci" > "$work/no-gate.yml"
check "a platform job without the tagged gate fails the graph check" '! graph "$work/no-gate.yml"'
yq '.jobs.release.if = "always() && needs.version.outputs.tagged == '"'"'true'"'"'"' "$ci" > "$work/always.yml"
check "a publishing job that runs after a failed need fails the graph check" '! graph "$work/always.yml"'
yq '.jobs.late-tests = {"runs-on": "ubuntu-24.04", "needs": ["version"], "steps": [{"run": "true"}]}' "$ci" > "$work/late.yml"
check "a non-publishing job after the version job fails the graph check" '! graph "$work/late.yml"'
sed "s|^\( *\)swift test --package-path SSMConnectKit$|\1swift test --package-path SSMConnectKit --filter 'SSMConnectHelperTests'|" "$ci" > "$work/filtered.yml"
check "a filter on the macOS package suite fails the graph check" '! cmp -s "$ci" "$work/filtered.yml" && ! graph "$work/filtered.yml"'
yq '.jobs.macos-package.runs-on = "ubuntu-24.04"' "$ci" > "$work/linux-suite.yml"
check "the macOS package suite on a Linux runner fails the graph check" '! graph "$work/linux-suite.yml"'
yq '.jobs.aws-client.continue-on-error = true' "$ci" > "$work/coe-job.yml"
check "a check job that may fail without failing fails the graph check" '! graph "$work/coe-job.yml"'
yq '(.jobs.macos-package.steps[] | select(.name == "Test the macOS package")).continue-on-error = true' "$ci" > "$work/coe-step.yml"
check "a check step that may fail without failing fails the graph check" '! cmp -s "$ci" "$work/coe-step.yml" && ! graph "$work/coe-step.yml"'
yq '.jobs.winget.if = .jobs.winget.if + " || true"' "$ci" > "$work/widened.yml"
check "a publishing gate widened with || fails the graph check" '! graph "$work/widened.yml"'
yq '.jobs.version.if = "always()"' "$ci" > "$work/version-always.yml"
check "a version job that runs after a failed check fails the graph check" '! graph "$work/version-always.yml"'
yq '.jobs.version.if = "!failure()"' "$ci" > "$work/version-notfailure.yml"
check "a version job gated on !failure() fails the graph check" '! graph "$work/version-notfailure.yml"'
yq '(.jobs.macos-package.steps[] | select(.name == "Test the macOS package")).if = "false"' "$ci" > "$work/skip-suite.yml"
check "a skipped macOS suite step fails the graph check" '! cmp -s "$ci" "$work/skip-suite.yml" && ! graph "$work/skip-suite.yml"'
yq '(.jobs.aws-client.steps[] | select(.name == "Test the AWS client package")).if = "false"' "$ci" > "$work/skip-aws.yml"
check "a skipped AWS client test step fails the graph check" '! cmp -s "$ci" "$work/skip-aws.yml" && ! graph "$work/skip-aws.yml"'
yq '.permissions.contents = "write"' "$ci" > "$work/wf-write.yml"
check "write permission for the whole workflow fails the graph check" '! graph "$work/wf-write.yml"'
yq '.jobs.release-scripts.permissions.contents = "write"' "$ci" > "$work/job-write.yml"
check "a check job with write permission fails the graph check" '! graph "$work/job-write.yml"'
yq '.jobs.release-scripts.environment = "winget"' "$ci" > "$work/job-env.yml"
check "a check job with an environment fails the graph check" '! graph "$work/job-env.yml"'
yq '.jobs.release-scripts.steps[0].env.TOKEN = "${{ secrets.WINGET_TOKEN }}"' "$ci" > "$work/job-secret.yml"
check "a check job reading a secret fails the graph check" '! graph "$work/job-secret.yml"'
TOKEN_EXPR="\${{ secrets['WINGET_TOKEN'] }}" yq '.jobs.release-scripts.steps[0].env.TOKEN = strenv(TOKEN_EXPR)' "$ci" > "$work/job-secret-bracket.yml"
check "a check job reading a secret by index fails the graph check" '! cmp -s "$ci" "$work/job-secret-bracket.yml" && ! graph "$work/job-secret-bracket.yml"'
yq '.jobs.inherit-check = {"uses": "./.github/workflows/preview.yml", "secrets": "inherit"} | .jobs.version.needs += ["inherit-check"]' "$ci" > "$work/job-inherit.yml"
check "a check job inheriting every secret fails the graph check" '! graph "$work/job-inherit.yml"'

# The Linux package version: a tilde before the prerelease so it sorts below its release, and only
# characters rpmbuild accepts in Version (letters, digits, . _ + ~ ^).
pkg() { SSM_PRINT_PACKAGE_VERSION=1 bash "$here/../../packaging/linux/build-packages.sh" "$1"; }
check "a stable version keeps its package version" '[ "$(pkg 1.2.3)" = 1.2.3 ]'
check "a prerelease sorts below its release" '[ "$(pkg 0.0.0-t28.7)" = "0.0.0~t28.7" ]'
check "a branch prerelease gives an RPM-legal version" '[ "$(pkg 0.8.0-feat-shared-swift-core.1)" = "0.8.0~feat.shared.swift.core.1" ] && [[ "$(pkg 0.8.0-feat-shared-swift-core.1)" =~ ^[0-9A-Za-z._+~^]+$ ]]'

[ "$failures" = 0 ] || { echo "$failures release check(s) failed"; exit 1; }
echo "Every release check passed."
