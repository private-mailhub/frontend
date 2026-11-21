#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd); temp=$(mktemp -d); trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin"; export PATH="$temp/bin:$PATH" MOCK_TRACE="$temp/trace" DEPLOY_BUCKET=test-bucket CODEDEPLOY_APP=frontend-test CODEDEPLOY_GROUP=local-frontend GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa GITHUB_RUN_ID=732 GITHUB_RUN_ATTEMPT=2
printf 'test artifact' > "$temp/frontend.zip"
cat > "$temp/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$1" "$2" >> "$MOCK_TRACE"
case "$1:$2" in
  s3api:get-bucket-versioning) printf '%s\n' "${MOCK_VERSIONING:-Enabled}" ;;
  s3api:put-object) [[ "$*" == *"--key frontend/$GITHUB_SHA/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT.zip"* && "$*" == *'--if-none-match *'* ]]; printf '%s\n' "${MOCK_VERSION:-test.version}" ;;
  deploy:create-deployment)
    while [[ $# -gt 0 && $1 != --revision ]]; do shift; done
    jq -e --arg bucket "$DEPLOY_BUCKET" --arg key "frontend/$GITHUB_SHA/$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT.zip" '.revisionType=="S3" and .s3Location=={bucket:$bucket,key:$key,bundleType:"zip",version:"test.version"}' <<< "$2" >/dev/null
    printf 'd-ABC123\n' ;;
  deploy:wait) [[ $3 == deployment-successful && $5 == d-ABC123 ]]; exit "${MOCK_WAIT:-0}" ;;
  *) exit 12 ;;
esac
MOCK
chmod +x "$temp/bin/aws"
run() { : > "$MOCK_TRACE"; bash "$root/deploy/publish-frontend.sh" "$temp/frontend.zip"; }
run; [[ $(wc -l < "$MOCK_TRACE") -eq 4 ]]
if MOCK_VERSIONING=Suspended run; then exit 1; fi; [[ $(wc -l < "$MOCK_TRACE") -eq 1 ]]
if MOCK_VERSION=None run; then exit 1; fi; [[ $(wc -l < "$MOCK_TRACE") -eq 2 ]]
if MOCK_WAIT=4 run; then exit 1; fi
# Build a tiny committed fixture; local settings and untracked hook files must not ship.
r="$temp/fixture"; mkdir -p "$r/deploy/codedeploy" "$r/dist/assets"; cp "$root/deploy/package-frontend.sh" "$r/deploy/"
for f in appspec.yml deploy/release.sh deploy/codedeploy/activate.sh; do printf 'fixture\n' > "$r/$f"; done
(cd "$r"; git init -q; git add .; git -c user.name=fixture -c user.email=test@example.invalid -c commit.gpgsign=false commit -qm fixture)
sha=$(git -C "$r" rev-parse HEAD); echo '<title>Mailhub</title><script src="/assets/app.js"></script>' > "$r/dist/index.html"; echo 'export{}' > "$r/dist/assets/app.js"; echo omit > "$r/.env"; echo omit > "$r/deploy/codedeploy/local-only"
(cd "$r"; bash deploy/package-frontend.sh "$sha" "$temp/first.zip"; touch dist/index.html; bash deploy/package-frontend.sh "$sha" "$temp/second.zip")
cmp "$temp/first.zip" "$temp/second.zip"; mkdir "$temp/unpacked"; unzip -qo "$temp/first.zip" -d "$temp/unpacked"; [[ $(cat "$temp/unpacked/revision.txt") == "$sha" ]]; [[ ! -e "$temp/unpacked/deploy/codedeploy/local-only" ]]; (cd "$temp/unpacked"; shasum -a 256 -c frontend.tar.gz.sha256; tar -tzf frontend.tar.gz > "$temp/list"); grep -qx 'assets/app.js' "$temp/list"; if grep -Eq '(^|/)(\.env|node_modules|\.git)(/|$)' "$temp/list"; then exit 1; fi
if grep -Eq 'EC2_SSH_KEY|authorize-security-group-ingress|scp |ssh ' "$root/.github/workflows/deploy.yml"; then echo 'Unexpected SSH configuration' >&2; exit 1; fi
printf 'PASS: deterministic allowlisted package, version-pinned S3 publish, guard conditions and CodeDeploy failure propagation\n'
