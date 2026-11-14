#!/usr/bin/env bash
# Structural: the lines of publish.yml that decide who may publish to Hex.
set -u
WF="$(cd "$(dirname "$0")/../.." && pwd)/workflows/publish.yml"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$2', got '$3')"; fail=1; fi; }
# job <name>: the lines of that job, up to the next top-level job.
job() { awk -v n="  $1:" '$0 == n {f=1; next} f && /^  [a-z]+:/ {exit} f' "$WF"; }

check "no step carries a Hex key" 0 "$(grep -c 'HEX_API_KEY' "$WF")"
check "no line reads a secret" 0 "$(grep -v '^ *#' "$WF" | grep -c 'secrets')"
check "only the publish job mints an OIDC token" 1 "$(grep -c 'id-token: write' "$WF")"
check "the publish job holds it" 1 "$(job publish | grep -c 'id-token: write')"
check "the guard job does not" 0 "$(job guard | grep -c 'id-token')"
check "the publish job keeps contents: read" 1 "$(job publish | grep -c '      contents: read')"
check "the publish job polls no checks, so it holds no checks permission" 0 "$(job publish | grep -c '      checks:')"
check "the publish job runs in prod, where hex.pm trusts it" 1 "$(job publish | grep -c '    environment: prod')"
check "the publish job runs on a tag push only" 1 "$(job publish | grep -c "    if: github.event_name == 'push'")"
for j in guard publish; do
  check "$j runs the Hex version check" 1 "$(job $j | grep -c 'run: bash .github/scripts/hex_workload_identity.sh')"
  check "$j checks Hex before anything uses it" 1 \
    "$([ "$(job $j | grep -n 'hex supports workload identity' | cut -d: -f1)" -lt "$(job $j | grep -nE 'publish.sh|publish_guard.sh' | head -1 | cut -d: -f1)" ] && echo 1 || echo 0)"
done
exit $fail
