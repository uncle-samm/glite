#!/bin/sh
# Tag the version in gleam.toml on main and push the tag. The Release workflow
# then tests it and publishes it to Hex.
set -eu

branch=$(git branch --show-current)
if [ "$branch" != "main" ]; then
  echo "Not on main (on $branch). Switch to main first." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "The working tree has uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

git fetch origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Local main differs from origin/main. Push or pull first." >&2
  exit 1
fi

make check

version=$(sed -n 's/^version = "\(.*\)"/\1/p' gleam.toml)
tag="v$version"
if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "Tag $tag already exists. Bump the version in gleam.toml first." >&2
  exit 1
fi

git tag "$tag"
git push origin "$tag"
echo "Pushed $tag. Watch the Release workflow on GitHub."
