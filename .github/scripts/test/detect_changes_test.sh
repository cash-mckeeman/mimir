#!/usr/bin/env bash
# The selection table (including the default row): which package jobs each changed path runs.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; fail=0
expect() { # desc, paths (printf %b), want: mimir workflows orchestration analytics integration
  local got; got="$(printf '%b' "$2" | bash "$HERE/detect_changes.sh" 2>/dev/null | grep -v '^ok=' | cut -d= -f2 | paste -sd' ' -)"
  if [ "$got" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (want '$3', got '$got')"; fail=1; fi
}
expect "mimir"             'mimir/lib/mimir.ex\n'              "true false true false true"
expect "workflows"         'mimir_workflows/lib/x.ex\n'        "false true true false true"
expect "orchestration"     'mimir_orchestration/mix.exs\n'     "false false true false true"
expect "analytics"         'mimir_analytics/priv/schema.sql\n' "false false false true true"
expect "integration"       'integration/test/x_test.exs\n'     "false false false false true"
expect "root mix.exs"      'mix.exs\n'                         "true true true true true"
expect ".github"           '.github/workflows/ci.yml\n'        "true true true true true"
expect ".hygiene"          '.hygiene/forbidden-paths.txt\n'    "true true true true true"
expect ".githooks"         '.githooks/pre-push\n'              "true true true true true"
expect ".gitignore"        '.gitignore\n'                      "true true true true true"
expect "LICENSE"           'LICENSE\n'                         "true true true true true"
expect "root README only"  'README.md\n'                       "false false false false false"
expect "unlisted path"     'CONTRIBUTING.md\n'                 "true true true true true"
expect "two packages"      'mimir/x.ex\nmimir_analytics/y.ex\n' "true false true true true"
expect "no paths"          ''                                  "false false false false false"
[ "$(bash "$HERE/detect_changes.sh" --all | grep -c '=true$')" = 6 ] && echo "ok: --all" || { echo "FAIL: --all"; fail=1; }
[ "$(printf 'mimir/x\n' | bash "$HERE/detect_changes.sh" 2>/dev/null | tail -1)" = "ok=true" ] && echo "ok: ok=true last" || { echo "FAIL: ok=true last"; fail=1; }
exit $fail
