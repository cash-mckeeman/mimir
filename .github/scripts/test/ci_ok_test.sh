#!/usr/bin/env bash
# ci-ok passes only when detect-changes succeeded with output, and every job either
# succeeded or was skipped because detect-changes excluded it.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; fail=0
det='"detect-changes":{"result":"success","outputs":{"ok":"true","mimir":"true","workflows":"false","orchestration":"true","analytics":"false","integration":"true"}}'
case_() { # desc, needs-json, want-exit, want-substring
  local out; out="$(printf '%s' "$2" | bash "$HERE/ci_ok.sh" 2>&1)"; local s=$?
  if [ "$s" = "$3" ] && grep -qF -- "$4" <<<"$out"; then echo "ok: $1"; else echo "FAIL: $1 (exit $s, want $3 and '$4')"; sed 's/^/    /' <<<"$out"; fail=1; fi
}
case_ "all selected green, unselected skipped" "{$det,\"repo-checks\":{\"result\":\"success\"},\"mimir-test\":{\"result\":\"success\"},\"workflows-test\":{\"result\":\"skipped\"}}" 0 "skip  workflows-test"
case_ "detect-changes failed" '{"detect-changes":{"result":"failure","outputs":{}},"mimir-test":{"result":"skipped"}}' 1 "detect-changes failure"
case_ "detect-changes printed nothing" '{"detect-changes":{"result":"success","outputs":{}},"mimir-test":{"result":"skipped"}}' 1 "detect-changes success (ok=)"
case_ "a selected job skipped" "{$det,\"repo-checks\":{\"result\":\"success\"},\"mimir-test\":{\"result\":\"skipped\"}}" 1 "FAIL  mimir-test: selected=true result=skipped"
case_ "a selected job failed" "{$det,\"repo-checks\":{\"result\":\"success\"},\"mimir-test\":{\"result\":\"failure\"}}" 1 "FAIL  mimir-test: selected=true result=failure"
case_ "a selected job cancelled" "{$det,\"repo-checks\":{\"result\":\"success\"},\"orchestration-test\":{\"result\":\"cancelled\"}}" 1 "result=cancelled"
case_ "repo-checks failed" "{$det,\"repo-checks\":{\"result\":\"failure\"}}" 1 "FAIL  repo-checks"
case_ "a job detect-changes knows nothing of" "{$det,\"repo-checks\":{\"result\":\"success\"},\"newpkg-test\":{\"result\":\"success\"}}" 1 "selected=missing"
exit $fail
