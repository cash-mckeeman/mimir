#!/usr/bin/env bash
# Execute the publisher with registry and Mix boundaries replaced by local fixtures.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.github/scripts" "$T/bin" "$T/mimir" "$T/mimir_analytics"
cp "$HERE/publish.sh" "$T/.github/scripts/"

cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
[ "${FAKE_RELEASE_EXISTS:-0}" = 1 ]
FAKE
cat > "$T/bin/mix" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "${PWD##*/}" "$*" "${MIX_ENV:-dev}" "${MIMIR_PUBLISH:-unset}" >> "$FAKE_PUBLISH_TRACE"
case "$*" in
  'deps.get') exit 0 ;;
  'mimir_analytics.setup')
    [ "${MIX_ENV:-}" = test ] && [ "${MIMIR_PUBLISH:-}" = 1 ] || exit 22
    [ "${FAKE_SETUP_FAIL:-0}" = 0 ] || exit 23
    touch "$FAKE_PUBLISH_STATE" ;;
  test)
    [ "${PWD##*/}" != mimir_analytics ] || [ -f "$FAKE_PUBLISH_STATE" ] || exit 24 ;;
  'hex.publish --yes') exit 0 ;;
  *) exit 25 ;;
esac
FAKE
chmod +x "$T/bin/curl" "$T/bin/mix"
fail=0
run_case() {
  local name="$1" package="$2" expected_status="$3" exists="$4" setup_fail="$5" status=0
  rm -f "$T/state"
  : > "$T/trace"
  (unset MIX_ENV; PATH="$T/bin:$PATH" FAKE_PUBLISH_TRACE="$T/trace" FAKE_PUBLISH_STATE="$T/state" \
    FAKE_RELEASE_EXISTS="$exists" FAKE_SETUP_FAIL="$setup_fail" \
    bash "$T/.github/scripts/publish.sh" 0.8.1 "$package") > "$T/output" 2>&1 || status=$?
  if [ "$status" = "$expected_status" ] && diff -u "$T/expected" "$T/trace"; then
    echo "ok: $name"
  else
    echo "FAIL: $name (exit $status, want $expected_status)"
    cat "$T/output" "$T/trace"
    fail=1
  fi
}

cat > "$T/expected" <<'TRACE'
mimir_analytics|deps.get|dev|1
mimir_analytics|mimir_analytics.setup|test|1
mimir_analytics|test|test|1
mimir_analytics|hex.publish --yes|dev|1
TRACE
run_case 'Analytics provisions extensions before tests and publication' mimir_analytics 0 0 0

cat > "$T/expected" <<'TRACE'
mimir_analytics|deps.get|dev|1
mimir_analytics|mimir_analytics.setup|test|1
TRACE
run_case 'setup failure prevents tests and publication' mimir_analytics 23 0 1

: > "$T/expected"
run_case 'an existing release skips setup and publication' mimir_analytics 0 1 0

cat > "$T/expected" <<'TRACE'
mimir|deps.get|dev|1
mimir|test|test|1
mimir|hex.publish --yes|dev|1
TRACE
run_case 'other packages retain their existing publication path' mimir 0 0 0
exit "$fail"
