#!/usr/bin/env bash
#
# Cut a new AnyDrag version.
#
# Scheme: MARKETING_VERSION = "YY.MM.<build>" (CalVer), where <build> is a
# monotonic integer (CURRENT_PROJECT_VERSION). The build number is the key
# Sparkle compares to decide "is this newer", so it MUST only ever increase —
# this script is the single place that touches it, +1 each release, to avoid
# hand-editing mistakes.
#
# It bumps both fields in project.yml, commits, and creates tag v<version>.
# It does NOT push by default (push is the irreversible release trigger) —
# pass --push to also push main + the tag.
#
# Usage:  scripts/bump-version.sh [--push]
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_YML="project.yml"
[ -f "$PROJECT_YML" ] || { echo "error: $PROJECT_YML not found (run from repo root)" >&2; exit 1; }

# Working tree must be clean EXCEPT for RELEASE_NOTES.html — uncommitted
# edits to the notes file are expected (Phase 1 of the release skill: you
# prepend this version's block before running this script), and the script
# folds them into the same release commit so history stays one-commit-per-release.
other_dirty=$(git status --porcelain -- . ':!RELEASE_NOTES.html')
if [ -n "$other_dirty" ]; then
  echo "error: working tree has changes other than RELEASE_NOTES.html — commit or stash first" >&2
  echo "$other_dirty" | sed 's/^/  /' >&2
  exit 1
fi

# `|| true`: don't let a no-match abort under `set -o pipefail` before the guard.
cur_build=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed -E 's/[^0-9]*([0-9]+).*/\1/' || true)
[ -n "$cur_build" ] || { echo "error: could not read CURRENT_PROJECT_VERSION from $PROJECT_YML" >&2; exit 1; }

new_build=$((cur_build + 1))
# Use LOCAL date, not UTC: the CalVer YY.MM is the release month as the human
# cutting the release experiences it. With `date -u` a release made just after
# local midnight on the 1st (e.g. 00:04 +0800 → still the previous month in UTC)
# would be stamped with the wrong month. Only the appcast pubDate stays UTC.
version="$(date +%y.%m).${new_build}"
tag="v${version}"

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "error: tag ${tag} already exists" >&2
  exit 1
fi

# The release pipeline ships RELEASE_NOTES.html (cumulative, EN + ZH per
# version) as the Sparkle appcast description AND extracts this version's
# section as the GitHub Release body. Nudge if the file has no block for the
# new version yet — non-blocking, but the GitHub Release body will fall back
# to auto-generated notes if the block is missing.
notes_file="RELEASE_NOTES.html"
heading="<h3>What's New in ${version}</h3>"
if [ ! -f "$notes_file" ]; then
  echo "⚠️  ${notes_file} is missing — Sparkle description will be empty and the GitHub Release will use auto-generated notes." >&2
elif ! grep -qF "$heading" "$notes_file"; then
  echo "⚠️  ${notes_file} has no '<h3>What's New in ${version}</h3>' block yet." >&2
  echo "    Add a new block at the TOP (with a paired '<h3>${version} 更新内容</h3>' section)" >&2
  echo "    before releasing, or the GitHub Release body will fall back to auto-generated notes." >&2
fi

# Update both fields (BSD/macOS sed).
sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:).*/\1 \"${version}\"/" "$PROJECT_YML"
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:).*/\1 \"${new_build}\"/" "$PROJECT_YML"

echo "Version → ${version}   (build ${cur_build} → ${new_build})"

# Fold uncommitted RELEASE_NOTES.html edits (Phase 1's new per-version block)
# into the release commit so history stays one-commit-per-release.
git add "$PROJECT_YML"
[ -f RELEASE_NOTES.html ] && git add RELEASE_NOTES.html
git commit -m "chore(release): ${version}" >/dev/null
git tag "$tag"
echo "Committed + tagged ${tag}."

if [ "${1:-}" = "--push" ]; then
  git push origin HEAD
  git push origin "$tag"
  echo "Pushed — CI release pipeline triggered for ${tag}."
else
  echo "Not pushed. To release:  git push origin HEAD && git push origin ${tag}"
fi
