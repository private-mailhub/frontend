#!/usr/bin/env bash
# Produce only compiled frontend files and reviewed CodeDeploy hooks, never the checkout or .env.
set -euo pipefail
umask 022
[[ $# == 2 && $1 =~ ^[0-9a-f]{40}$ ]] || { echo 'usage: package-frontend.sh <git-sha> <new-zip-path>' >&2; exit 2; }
sha=$1
out="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
[[ ! -e "$out" && ! -L "$out" ]] || { echo 'output must be a new file' >&2; exit 1; }
cd "$(dirname "$0")/.."
[[ $(git rev-parse HEAD) == "$sha" ]] || { echo 'checkout/revision mismatch' >&2; exit 1; }
[[ -s dist/index.html && -d dist/assets && -s appspec.yml && -d deploy/codedeploy && -z $(find dist ! -type d ! -type f -print -quit) ]] || { echo 'missing production dist or unsafe content' >&2; exit 1; }
[[ -z $(find dist \( -name .git -o -name .DS_Store -o -name ".env*" -o -name "*.pem" -o -name node_modules \) -print -quit) ]] || { echo 'unexpected private/build input' >&2; exit 1; }
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/content" "$stage/bundle/deploy"
# Hooks and manifests come from the Git object, not untracked operator files.
git archive "$sha" appspec.yml deploy/release.sh deploy/codedeploy | tar -x -C "$stage/bundle"
cp -R dist/. "$stage/content/"
[[ -z $(find "$stage/content" "$stage/bundle" ! -type f ! -type d -print -quit) ]] || { echo 'non-regular archive content' >&2; exit 1; }
# Normalize copied timestamps and ordering so rebuilding unchanged files yields the same payload.
export LC_ALL=C TZ=UTC COPYFILE_DISABLE=1
(cd "$stage/content"; find . -mindepth 1 -exec touch -t 200001010000.00 {} +; find . -mindepth 1 -print | sed 's@^\./@@' | sort > "$stage/names"; if tar --version | grep -q 'GNU tar'; then tar --format=ustar --owner=0 --group=0 --numeric-owner --no-recursion -cf - -T "$stage/names"; else tar --format=ustar --uid 0 --gid 0 --uname root --gname root --no-recursion -cf - -T "$stage/names"; fi) | gzip -n > "$stage/bundle/frontend.tar.gz"
cd "$stage/bundle"; printf '%s\n' "$sha" > revision.txt
if command -v sha256sum >/dev/null; then sha256sum frontend.tar.gz; else shasum -a 256 frontend.tar.gz; fi > frontend.tar.gz.sha256
find . -type f -exec touch -t 200001010000.00 {} +
find . -type f -print | sed 's@^\./@@' | sort | zip -Xq "$out" -@
