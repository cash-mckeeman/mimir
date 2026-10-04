#!/usr/bin/env bash
# The publish guard against fixture repos, with `mix` and `gh` faked on PATH.
# The fixtures are throwaway git repos under mktemp, never a jj repository.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; fail=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\n[ "$1" = publish_order ] && { printf "%%b" "$FAKE_ORDER"; exit 0; }\nexit 0\n' > "$T/bin/mix"
cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
[ -n "${FAKE_GH_FAIL:-}" ] && exit 1
filter=""; while [ $# -gt 0 ]; do case "$1" in --jq) filter="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s' "$FAKE_RUNS" | jq "$filter"
FAKE
chmod +x "$T/bin/mix" "$T/bin/gh"

repo() { # versions for mimir mimir_workflows mimir_orchestration -> a fixture repo; prints its path
  local d; d="$(mktemp -d "$T/repo.XXXX")"; mkdir -p "$d/.github/scripts"
  cp "$HERE/publish_guard.sh" "$d/.github/scripts/"
  local i=0; for p in mimir mimir_workflows mimir_orchestration; do i=$((i+1))
    mkdir -p "$d/$p"; printf 'defmodule X do\n  @version "%s"\nend\n' "${!i}" > "$d/$p/mix.exs"; done
  ( cd "$d" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm fixture \
    && git update-ref refs/remotes/origin/main HEAD ); echo "$d"
}
OK='{"check_runs":[{"status":"completed","conclusion":"success","completed_at":"2026-10-02T00:00:00Z"}]}'
ORDER='mimir\nmimir_workflows\nmimir_orchestration\n'
guard() { # desc, repo, tag, sha, runs, order, want-exit, want-substring
  local out s
  out="$(cd "$2" && PATH="$T/bin:$PATH" TAG="$3" SHA="$4" REPO=o/r FAKE_RUNS="$5" FAKE_ORDER="$6" FAKE_GH_FAIL="${FAKE_GH_FAIL:-}" \
    CI_OK_POLL_SECONDS=0 CI_OK_MAX_POLLS=2 GITHUB_OUTPUT="$2/out" bash "$2/.github/scripts/publish_guard.sh" 2>&1)"; s=$?
  if [ "$s" = "$7" ] && grep -qF -- "$8" <<<"$out"; then echo "ok: $1"; else echo "FAIL: $1 (exit $s, want $7 and '$8')"; sed 's/^/    /' <<<"$out"; fail=1; fi
}
r="$(repo 0.7.0 0.7.0 0.7.0)"; h="$(git -C "$r" rev-parse HEAD)"
guard "a lockstep tag passes"              "$r" v0.7.0 "$h" "$OK" "$ORDER" 0 "guard: publish 0.7.0: mimir mimir_workflows mimir_orchestration"
guard "a v* tag with a patch is refused"   "$r" v0.7.1 "$h" "$OK" "$ORDER" 1 "FAIL tag: v0.7.1"
guard "an unknown package tag is refused"  "$r" mimir_ui-v0.7.1 "$h" "$OK" "$ORDER" 1 "FAIL tag: mimir_ui-v0.7.1: mimir_ui is not in the publish order"
guard "a package tag at patch 0 is refused" "$r" mimir-v0.7.0 "$h" "$OK" "$ORDER" 1 "must be <package>-vX.Y.Z with Z > 0"
guard "no ci-ok run is red"                "$r" v0.7.0 "$h" '{"check_runs":[]}' "$ORDER" 1 "FAIL ci-ok: no ci-ok check run"
guard "a pending ci-ok times out red"      "$r" v0.7.0 "$h" '{"check_runs":[{"status":"in_progress","conclusion":null,"completed_at":null}]}' "$ORDER" 1 "still pending after 2 polls"
guard "the latest ci-ok decides (green)"   "$r" v0.7.0 "$h" '{"check_runs":[{"status":"completed","conclusion":"failure","completed_at":"2026-10-02T00:00:00Z"},{"status":"completed","conclusion":"success","completed_at":"2026-10-02T01:00:00Z"}]}' "$ORDER" 0 "guard: publish"
guard "the latest ci-ok decides (red)"     "$r" v0.7.0 "$h" '{"check_runs":[{"status":"completed","conclusion":"success","completed_at":"2026-10-02T00:00:00Z"},{"status":"completed","conclusion":"failure","completed_at":"2026-10-02T01:00:00Z"}]}' "$ORDER" 1 "concluded failure"
FAKE_GH_FAIL=1 guard "a failed check-runs query is red" "$r" v0.7.0 "$h" "$OK" "$ORDER" 1 "FAIL ci-ok: the check-runs query"
guard "an empty publish order is red"      "$r" v0.7.0 "$h" "$OK" "" 1 "FAIL order: mix publish_order printed nothing"
r2="$(repo 0.7.0 0.7.0-dev 0.7.0)"; h2="$(git -C "$r2" rev-parse HEAD)"
guard "a version mismatch is named"        "$r2" v0.7.0 "$h2" "$OK" "$ORDER" 1 "FAIL version: mimir_workflows @version 0.7.0-dev != tag version 0.7.0"
side="$(cd "$r" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m side && git rev-parse HEAD)"
guard "a commit not on main is refused"    "$r" v0.7.0 "$side" "$OK" "$ORDER" 1 "FAIL reachable"
exit $fail
