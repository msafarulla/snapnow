#!/bin/zsh
# Tags HEAD with the pubspec version and publishes a GitHub release, so SnapNow's update check
# (the launch notice and "Check for Updates…") sees it as the latest. Run right after pushing the commit:
#   tools/release.sh
# Idempotent: an existing tag or release is left alone.
set -e
cd "$(dirname "$0")/.."
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
if gh release view "$tag" --repo msafarulla/snapnow >/dev/null 2>&1; then
  echo "release $tag already published"
else
  gh release create "$tag" --repo msafarulla/snapnow --title "SnapNow $version" --notes "SnapNow $version"
  echo "published release $tag"
fi
