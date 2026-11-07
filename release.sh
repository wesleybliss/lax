#!/usr/bin/env bash
# Cuts a release: bumps `.version` in build.zig.zon (patch by default), commits
# it, tags vX.Y.Z and pushes both, which starts the release workflow.
#
#   ./release.sh            0.1.2 -> 0.1.3
#   ./release.sh --minor    0.1.2 -> 0.2.0
#   ./release.sh --major    0.1.2 -> 1.0.0
#   ./release.sh -n         show what would happen, change nothing
set -euo pipefail
cd "$(dirname "$0")"

bump=patch
dry=0
for arg in "$@"; do
    case "$arg" in
        --major) bump=major ;;
        --minor) bump=minor ;;
        --patch) bump=patch ;;
        -n | --dry-run) dry=1 ;;
        -h | --help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

zon=build.zig.zon
current=$(sed -n 's/.*\.version = "\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$zon")
[ -n "$current" ] || { echo "no X.Y.Z .version in $zon" >&2; exit 1; }

IFS=. read -r major minor patch <<<"$current"
case "$bump" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
esac
next="$major.$minor.$patch"
tag="v$next"

branch=$(git symbolic-ref --short HEAD)
echo "$current -> $next ($tag, from $branch)"
[ "$dry" = 1 ] && exit 0

git fetch --quiet --tags origin
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "tag $tag already exists" >&2
    exit 1
fi
if [ -n "$(git rev-list "HEAD..origin/$branch" 2>/dev/null)" ]; then
    echo "origin/$branch has commits you don't: pull first" >&2
    exit 1
fi

sed -i "s/\.version = \"$current\"/.version = \"$next\"/" "$zon"
# Only the version file goes in; other uncommitted work stays out of the release commit
git commit --quiet -o "$zon" -m "Release $tag"
git tag -a "$tag" -m "$tag"
git push --atomic origin "$branch" "refs/tags/$tag"
echo "pushed $tag"
