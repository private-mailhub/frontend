#!/usr/bin/env bash
# Create the CodeDeploy revision from an already-built frontend dist directory.
set -Eeuo pipefail

usage() {
  printf 'Usage: %s <40-character-lowercase-sha> <output-bundle.zip>\n' "$0" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage
  exit 64
fi

release_sha="$1"
output_bundle="$2"
if [[ ! "$release_sha" =~ ^[0-9a-f]{40}$ ]]; then
  fail 'release SHA must be exactly 40 lowercase hexadecimal characters'
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
dist_dir="$repo_root/dist"
appspec="$repo_root/appspec.yml"
release_script="$repo_root/deploy/release.sh"
hooks_dir="$repo_root/deploy/codedeploy"
output_dir=$(cd "$(dirname "$output_bundle")" && pwd)
output_bundle="$output_dir/$(basename "$output_bundle")"
[[ ! -L "$output_bundle" ]] || fail "output bundle path must not be a symbolic link: $output_bundle"

for required_path in "$dist_dir/index.html" "$appspec" "$release_script" "$hooks_dir"; do
  [[ -e "$required_path" && ! -L "$required_path" ]] || fail "required package input is missing or a symbolic link: $required_path"
done
[[ -d "$hooks_dir" ]] || fail "CodeDeploy hooks path must be a directory"
[[ -x "$release_script" ]] || fail "deploy/release.sh must be executable"

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/mailhub-frontend-package.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT

install -m 0644 "$appspec" "$staging_dir/appspec.yml"
mkdir -p "$staging_dir/deploy"
install -m 0755 "$release_script" "$staging_dir/deploy/release.sh"
cp -R "$hooks_dir" "$staging_dir/deploy/codedeploy"
printf '%s\n' "$release_sha" > "$staging_dir/revision.txt"

tar -czf "$staging_dir/frontend.tar.gz" -C "$dist_dir" .
(
  cd "$staging_dir"
  sha256sum frontend.tar.gz > frontend.tar.gz.sha256
  zip -q -r "$staging_dir/revision.zip" appspec.yml deploy revision.txt frontend.tar.gz frontend.tar.gz.sha256
)
mv -f "$staging_dir/revision.zip" "$output_bundle"

printf '%s\n' "$output_bundle"
