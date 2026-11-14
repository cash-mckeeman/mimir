#!/usr/bin/env bash
# publish.sh VERSION PACKAGE... — publish in the given order. A package already on
# Hex at VERSION is skipped, so a rerun after a partial failure publishes only what
# is missing. Each package's suite runs against Hex siblings before it publishes.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"; summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
# An empty version or package list would publish nothing and still exit 0: a release
# that silently does nothing. Refuse it.
[ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo "publish.sh: needs a version and at least one package (got version '${1:-}', $(( $# > 0 ? $# - 1 : 0 )) packages)" >&2; exit 1; }
version="$1"; shift
for pkg in "$@"; do
  if curl -sf "https://hex.pm/api/packages/$pkg/releases/$version" >/dev/null; then
    echo "- $pkg $version: skipped, already on Hex" | tee -a "$summary"; continue
  fi
  cd "$root/$pkg"
  for attempt in $(seq 1 10); do
    MIMIR_PUBLISH=1 mix deps.get && break
    [ "$attempt" = 10 ] && { echo "$pkg: siblings did not resolve from Hex after 10 attempts" >&2; exit 1; }
    sleep 30
  done
  if [ "$pkg" = mimir_analytics ]; then
    MIX_ENV=test MIMIR_PUBLISH=1 mix mimir_analytics.setup
  fi
  MIX_ENV=test MIMIR_PUBLISH=1 mix test
  MIMIR_PUBLISH=1 mix hex.publish --yes
  echo "- $pkg $version: published" | tee -a "$summary"
done
