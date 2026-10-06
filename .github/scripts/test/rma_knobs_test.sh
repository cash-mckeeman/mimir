#!/usr/bin/env bash
# mimir_orchestration's dependency knobs (RMA, req_llm), read from its mix.exs without fetching deps.
set -u
cd "$(dirname "$0")/../../../mimir_orchestration"; fail=0
q='IO.inspect(List.keyfind(Mix.Project.config()[:deps], :req_managed_agents, 0))'
knob() { # desc, want-substring, VAR=value...
  local desc="$1" want="$2" out; shift 2
  out="$(env "$@" mix run --no-start --no-compile --no-deps-check -e "$q" 2>&1 </dev/null)"
  if grep -qF -- "$want" <<<"$out"; then echo "ok: $desc"; else echo "FAIL: $desc (want '$want')"; sed 's/^/    /' <<<"$out" | head -3; fail=1; fi
}
knob "publishing refuses MIMIR_WITHOUT_RMA"   "MIMIR_PUBLISH cannot be combined" MIMIR_PUBLISH=1 MIMIR_WITHOUT_RMA=1
knob "publishing refuses MIMIR_RMA_PIN"       "MIMIR_PUBLISH cannot be combined" MIMIR_PUBLISH=1 MIMIR_RMA_PIN=0.10.0
knob "publishing refuses MIMIR_WITHOUT_REQ_LLM" "MIMIR_PUBLISH cannot be combined with MIMIR_WITHOUT_REQ_LLM" MIMIR_PUBLISH=1 MIMIR_WITHOUT_REQ_LLM=1
knob "a pre-release pin is outside the range" 'MIMIR_RMA_PIN "0.11.0-rc.1" is outside' MIMIR_RMA_PIN=0.11.0-rc.1
exit $fail
