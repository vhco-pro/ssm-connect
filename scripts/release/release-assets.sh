#!/usr/bin/env bash
# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
#
# The release steps every platform job shares, through the GitHub CLI:
#
#   ensure-release <tag> <title> [--prerelease]   create the release once, without the latest mark
#   upload-missing <tag> <file>...                upload only assets the release does not hold yet
#   reuse-published <tag> <file>                  replace a rebuilt file with the published one
#   mark-latest                                   mark the newest release that has a macOS ZIP
#
# Published assets never change: upload-missing skips a name the release already holds instead of
# replacing it, so a rerun job fills only what is missing and Homebrew and WinGet checksums stay
# valid. mark-latest is idempotent and converges on the newest release with a macOS ZIP, so a late
# older macOS build never displaces a newer one, and Homebrew's sync, which reads the latest
# release, always finds a ZIP. The release workflow runs it in the release-latest concurrency group.
# reuse-published exists because builds are not byte-reproducible: when a rerun job's artifact is
# already published, everything derived from it (checksums, manifests, package checks) must come
# from the published file. It prints reused=true or reused=false.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

# Prints the tag of the newest non-draft, non-prerelease release that has an
# SSMConnect-<version>.zip asset, reading the releases API's JSON array on stdin.
newest_with_zip() {
  jq -r '.[] | select(.draft == false and .prerelease == false)
              | select(any(.assets[]?; .name | test("^SSMConnect-.*\\.zip$")))
              | .tag_name' |
    sed 's/^v//' | sort -V | tail -1 | sed '/./s/^/v/'
}

case "${1:-}" in
  ensure-release)
    tag="$2"; title="$3"; prerelease="${4:-}"
    if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
      echo "Release $tag exists."
    else
      args=(release create "$tag" --repo "$repo" --title "$title" --generate-notes --latest=false
            --target "${GITHUB_SHA:?GITHUB_SHA is required}")
      [ "$prerelease" = "--prerelease" ] && args+=(--prerelease)
      gh "${args[@]}"
      echo "Created release $tag without the latest mark."
    fi
    ;;
  upload-missing)
    tag="$2"; shift 2
    existing="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')"
    for file in "$@"; do
      name="$(basename "$file")"
      if grep -qxF "$name" <<<"$existing"; then
        echo "Kept the published $name; published assets never change."
      else
        gh release upload "$tag" "$file" --repo "$repo"
        echo "Uploaded $name."
      fi
    done
    ;;
  reuse-published)
    tag="$2"; file="$3"; name="$(basename "$file")"
    if gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' | grep -qxF "$name"; then
      gh release download "$tag" --repo "$repo" --pattern "$name" --dir "$(dirname "$file")" --clobber
      echo "Using the published $name; checksums and manifests describe it, not this rebuild."
      echo "reused=true"
    else
      echo "reused=false"
    fi
    ;;
  mark-latest)
    newest="$(gh api --paginate "repos/$repo/releases?per_page=100" | jq -s 'add' | newest_with_zip)"
    if [ -z "$newest" ]; then echo "No release has a macOS ZIP yet."; exit 0; fi
    current="$(gh api "repos/$repo/releases/latest" --jq .tag_name 2>/dev/null || true)"
    if [ "$current" = "$newest" ]; then
      echo "$newest is already the latest release."
    else
      gh release edit "$newest" --repo "$repo" --latest
      echo "Marked $newest as the latest release (was ${current:-none})."
    fi
    ;;
  newest-with-zip)
    newest_with_zip
    ;;
  *)
    echo "usage: $0 ensure-release|upload-missing|reuse-published|mark-latest|newest-with-zip ..." >&2
    exit 2
    ;;
esac
