#!/usr/bin/env bash
# Direct/offline publication retains the legacy SHA + dist-wrapped archive interface.
# CodeDeploy uses --prepare / --activate on its own flat, checksummed revision.
set -Eeuo pipefail
umask 022
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ $# != 2 ]]; then
  printf 'Usage: %s SHA ARCHIVE | --prepare BUNDLE | --activate BUNDLE\n' "$0" >&2
  exit 64
fi
# One common FE/BE advisory lock per invocation. Keep it through activation,
# HTTPS proof and any recovery. Neither the hooks nor the helper reacquire it.
lock=${MAILHUB_DEPLOY_LOCK:-/var/lock/mailhub-deploy.lock}
mkdir -p -- "$(dirname -- "$lock")"
exec 9>>"$lock"
flock -x 9
exec python3 -B "$here/codedeploy/release.py" "$@"
