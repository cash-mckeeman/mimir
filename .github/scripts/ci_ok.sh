#!/usr/bin/env bash
# ci_ok.sh < toJSON(needs) — the aggregate gate branch protection requires.
# Red when detect-changes failed, was cancelled or produced no `ok`; when any
# selected job failed, was cancelled or was skipped; and when a job is not one
# detect-changes knows. A skip is green only if detect-changes excluded the job.
set -uo pipefail
needs="$(cat)"
det_result="$(jq -r '."detect-changes".result // "missing"' <<<"$needs")"
det_ok="$(jq -r '."detect-changes".outputs.ok // ""' <<<"$needs")"
if [ "$det_result" != success ] || [ "$det_ok" != true ]; then
  echo "ci-ok: detect-changes $det_result (ok=$det_ok)"; exit 1
fi
fail=0
while IFS=$'\t' read -r job result; do
  [ "$job" = detect-changes ] && continue
  if [ "$job" = repo-checks ]; then selected=true
  else selected="$(jq -r --arg p "${job%%-*}" '."detect-changes".outputs[$p] // "missing"' <<<"$needs")"; fi
  case "$selected:$result" in
    true:success)  echo "ok    $job" ;;
    false:skipped) echo "skip  $job (detect-changes excluded it)" ;;
    *)             echo "FAIL  $job: selected=$selected result=$result"; fail=1 ;;
  esac
done < <(jq -r 'to_entries[] | [.key, .value.result] | @tsv' <<<"$needs")
exit $fail
