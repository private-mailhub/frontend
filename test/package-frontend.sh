#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_root=$(mktemp -d)
created_appspec=false
created_hooks=false
cleanup() {
  rm -rf "$test_root"
  if [[ "$created_appspec" == true ]]; then rm -f "$repo_root/appspec.yml"; fi
  if [[ "$created_hooks" == true ]]; then rm -rf "$repo_root/deploy/codedeploy"; fi
}
trap cleanup EXIT

if [[ ! -f "$repo_root/appspec.yml" ]]; then
  printf 'version: 0.0\nos: linux\nfiles: []\n' > "$repo_root/appspec.yml"
  created_appspec=true
fi
if [[ ! -d "$repo_root/deploy/codedeploy" ]]; then
  mkdir -p "$repo_root/deploy/codedeploy"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo_root/deploy/codedeploy/test-hook.sh"
  chmod +x "$repo_root/deploy/codedeploy/test-hook.sh"
  created_hooks=true
fi

mkdir -p "$repo_root/dist/assets"
printf '<!doctype html>\n' > "$repo_root/dist/index.html"
printf 'asset\n' > "$repo_root/dist/assets/app.js"
sha=abcdef0123456789abcdef0123456789abcdef01
bundle="$test_root/mailhub-frontend-$sha.zip"
"$repo_root/deploy/package-frontend.sh" "$sha" "$bundle" >/dev/null

unzip -Z1 "$bundle" | sort > "$test_root/bundle-contents"
for required in appspec.yml deploy/release.sh revision.txt frontend.tar.gz frontend.tar.gz.sha256; do
  grep -Fx "$required" "$test_root/bundle-contents" >/dev/null || {
    printf 'FAIL: bundle is missing %s\n' "$required" >&2
    exit 1
  }
done
grep -Eq '^deploy/codedeploy/' "$test_root/bundle-contents" || {
  printf 'FAIL: bundle is missing CodeDeploy hooks\n' >&2
  exit 1
}
unzip -p "$bundle" revision.txt | grep -Fx "$sha" >/dev/null
unzip -p "$bundle" frontend.tar.gz > "$test_root/frontend.tar.gz"
unzip -p "$bundle" frontend.tar.gz.sha256 > "$test_root/frontend.tar.gz.sha256"
(
  cd "$test_root"
  sha256sum --check frontend.tar.gz.sha256
)
if tar -tzf "$test_root/frontend.tar.gz" | grep -Eq '(^|/)dist/'; then
  printf 'FAIL: frontend archive must contain flat dist contents\n' >&2
  exit 1
fi
tar -tzf "$test_root/frontend.tar.gz" | grep -Eq '(^|\./)index.html$'
tar -tzf "$test_root/frontend.tar.gz" | grep -Eq '(^|\./)assets/app.js$'

if "$repo_root/deploy/package-frontend.sh" ABCDEF0123456789ABCDEF0123456789ABCDEF01 "$test_root/invalid.zip" >/dev/null 2>&1; then
  printf 'FAIL: package script accepted an uppercase SHA\n' >&2
  exit 1
fi
if grep -Eqi '(ssh|scp|EC2_SECURITY_GROUP|authorize-security-group-ingress|revoke-security-group-ingress)' "$repo_root/.github/workflows/deploy.yml"; then
  printf 'FAIL: CodeDeploy workflow must not contain SSH or ingress controls\n' >&2
  exit 1
fi

printf 'PASS: CodeDeploy revision has required root files, a verified flat frontend archive, and no SSH ingress workflow\n'
