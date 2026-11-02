#!/bin/zsh
# Tags HEAD with the pubspec version and pushes the tag. CI (.github/workflows/build.yml) then builds
# macOS, Windows and Linux and publishes the GitHub Release with those builds attached, which is what
# SnapNow's update check (the launch notice and "Check for Updates…") picks up as the latest version.
# Run right after pushing the commit:
#   tools/release.sh
# Idempotent: an existing tag is left alone. Don't create the release by hand: CI creates it as a draft
# with the builds and then publishes it, and a release that exists before the builds do is empty.
set -e
cd "$(dirname "$0")/.."
repo=msafarulla/snapnow
version=$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' pubspec.yaml)
[[ -n "$version" ]] || { echo "no version in pubspec.yaml" >&2; exit 1; }
tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "tag $tag already exists"
else
  git tag "$tag"
  echo "tagged $tag"
fi
git push -q origin "$tag"
if gh release view "$tag" --repo "$repo" --json assets --jq '.assets|length' 2>/dev/null | grep -qx 3; then
  echo "release $tag already published with its builds"
  exit 0
fi
# Wait for the tag's workflow run to appear, then follow it to the end
echo "waiting for the $tag build…"
run=
for _ in {1..30}; do
  run=$(gh run list --repo "$repo" --workflow Build --branch "$tag" --event push --limit 1 --json databaseId --jq '.[0].databaseId // empty')
  [[ -n "$run" ]] && break
  sleep 5
done
[[ -n "$run" ]] || { echo "no workflow run for $tag yet: https://github.com/$repo/actions" >&2; exit 1; }
gh run watch "$run" --repo "$repo" --exit-status --interval 20 >/dev/null || {
  echo "build failed: https://github.com/$repo/actions/runs/$run" >&2; exit 1; }
echo "published release $tag with $(gh release view "$tag" --repo "$repo" --json assets --jq '.assets|length') builds"
echo "https://github.com/$repo/releases/tag/$tag"
