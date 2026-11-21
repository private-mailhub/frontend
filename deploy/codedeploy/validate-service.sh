#!/usr/bin/env bash
set -Eeuo pipefail
bundle=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
exec "$bundle/deploy/release.sh" --activate "$bundle"
