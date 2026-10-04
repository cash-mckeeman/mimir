#!/usr/bin/env bash
# The publish guard: what TAG publishes, and whether it may.
#   TAG   vX.Y.0 (every package `mix publish_order` prints) or <package>-vX.Y.Z with Z > 0
#   SHA   the commit the tag names;  REPO  owner/name;  GH_TOKEN for `gh api`
# Every check runs and prints `FAIL <check>: <reason>`; the exit is 1 if any failed,
# so a drill can assert the one line it targets. On success it writes version= and
# packages= to $GITHUB_OUTPUT. Bounds: CI_OK_POLL_SECONDS (30) x CI_OK_MAX_POLLS (40).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${GITHUB_OUTPUT:-/dev/null}"; poll="${CI_OK_POLL_SECONDS:-30}"; max_polls="${CI_OK_MAX_POLLS:-40}"
fail=0; bad() { echo "FAIL $1: $2"; fail=1; }

order="$(cd "$root" && mix publish_order)" || { echo "FAIL order: mix publish_order exited non-zero"; exit 1; }
[ -n "$order" ] || { echo "FAIL order: mix publish_order printed nothing"; exit 1; }

packages=""; version=""
case "$TAG" in
  v*)
    version="${TAG#v}"; packages="$order"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.0$ ]] || bad tag "$TAG: a v* tag is a lockstep minor and must be vX.Y.0" ;;
  *-v*)
    pkg="${TAG%-v*}"; version="${TAG##*-v}"; packages="$pkg"
    grep -qxF "$pkg" <<<"$order" || bad tag "$TAG: $pkg is not in the publish order"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[1-9][0-9]*$ ]] || bad tag "$TAG: a package tag is a patch and must be <package>-vX.Y.Z with Z > 0" ;;
  *) bad tag "$TAG matches neither vX.Y.0 nor <package>-vX.Y.Z" ;;
esac

for pkg in $packages; do
  f="$root/$pkg/mix.exs"
  [ -f "$f" ] || { bad version "$pkg/mix.exs does not exist"; continue; }
  found="$(sed -nE 's/^  @version "([^"]+)"$/\1/p' "$f")"
  [ "$(grep -c . <<<"$found")" = 1 ] || { bad version "$pkg/mix.exs must set @version exactly once (found: ${found:-none})"; continue; }
  [ "$found" = "$version" ] || bad version "$pkg @version $found != tag version $version"
done

git -C "$root" merge-base --is-ancestor "$SHA" origin/main 2>/dev/null || bad reachable "$SHA is not reachable from origin/main"

polls=0
while :; do
  if ! runs="$(gh api "repos/$REPO/commits/$SHA/check-runs?check_name=ci-ok&per_page=100" --jq '[.check_runs[] | {status, conclusion, completed_at}]')"; then
    bad ci-ok "the check-runs query for $SHA failed"; break
  fi
  if [ "$(jq length <<<"$runs")" -eq 0 ]; then bad ci-ok "no ci-ok check run on $SHA"; break; fi
  if [ "$(jq '[.[] | select(.status != "completed")] | length' <<<"$runs")" -gt 0 ]; then
    if [ "$polls" -ge "$max_polls" ]; then bad ci-ok "ci-ok on $SHA still pending after $polls polls"; break; fi
    polls=$((polls + 1)); sleep "$poll"; continue
  fi
  latest="$(jq -r 'sort_by(.completed_at) | last | .conclusion' <<<"$runs")"
  [ "$latest" = success ] || bad ci-ok "the latest ci-ok on $SHA concluded $latest"
  break
done

# Patch floor: a patch of a package with siblings must pass against the lowest
# sibling versions its requirements admit, fetched from Hex.
if [[ "$TAG" == *-v* ]] && [ -f "$root/$packages/mix.exs" ] && grep -q 'defp sibling(' "$root/$packages/mix.exs"; then
  ( cd "$root/$packages" && MIMIR_PUBLISH=floor mix deps.get && MIX_ENV=test MIMIR_PUBLISH=floor mix compile --force --warnings-as-errors && MIX_ENV=test MIMIR_PUBLISH=floor mix test ) >&2 \
    || bad floor "$packages fails against its lowest admitted siblings; raise the floor with sibling(app, \"~> X.Y.N\")"
fi

for p in $order; do
  grep -qxF "$p" <<<"$packages" || echo "not selected: $p" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
done
if [ "$fail" = 0 ]; then
  { echo "version=$version"; echo "packages=$(echo $packages)"; } >> "$out"
  echo "guard: publish $version: $(echo $packages)"
fi
exit "$fail"
