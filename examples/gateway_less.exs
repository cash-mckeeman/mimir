# Gateway-less mode: the routing oracle, in-process, no service required.
#
# This is Mimir's headline claim. A single application can link the library
# directly and consult the same oracle a fleet-scale gateway would run behind
# an HTTP hop — same descriptor contract, same decision record, just called as
# a function instead of a request. There is no server here, no network call,
# no minted key. Everything below happens inside this one BEAM process.
#
# What this script does:
#
#   1. configures a small catalog (2-3 entries across lanes) and pricing —
#      normally this lives in config/config.exs; it's inlined here so the
#      script is fully self-contained
#   2. parses a workload descriptor with `Mimir.Descriptor.parse/1`, including
#      the optional `agent:` identity, and shows it flow through to the audit
#      record
#   3. assembles the degenerate `Mimir.Snapshot` (no health data, no live
#      budget source — everything defaults to healthy/unlimited)
#   4. calls `Mimir.Oracle.decide/4` and builds a `Mimir.DecisionRecord` for
#      the placement it returns
#   5. calls it again with a descriptor the catalog can't satisfy, to show the
#      `:no_candidate` shape and its reasons
#
# Run it (no environment variables, no network):
#
#     mix run examples/gateway_less.exs

# ── 1. Configure the catalog + pricing in-script ────────────────────────────
#
# In a real app this is `config/config.exs`. It's `Application.put_env/3` here
# only so the example is one file with nothing to set up first.
Application.put_env(:mimir, :catalog, [
  %{
    id: "local-qwen",
    model: "ollama:qwen3",
    lane: "local",
    runtime: "local",
    capabilities: [:tools],
    priority: 10
  },
  %{
    id: "claude-haiku",
    model: "anthropic:claude-haiku-4-5",
    lane: "anthropic",
    runtime: "managed",
    capabilities: [:tools, :vision],
    priority: 50
  },
  %{
    id: "claude-sonnet",
    model: "anthropic:claude-sonnet-4-6",
    lane: "anthropic-premium",
    runtime: "managed",
    capabilities: [:tools, :vision, :long_context],
    priority: 100
  }
])

# Local model has no metered rate; only the Anthropic entries carry pricing —
# the oracle defaults an unpriced model to zero cost, so `local-qwen` always
# passes the cost filter (see `Mimir.Oracle`'s moduledoc for that rule).
Application.put_env(:mimir, :pricing, %{
  "anthropic:claude-haiku-4-5" => %{input: 1_000_000, output: 5_000_000},
  "anthropic:claude-sonnet-4-6" => %{input: 3_000_000, output: 15_000_000}
})

# ── 2. Parse a workload descriptor ───────────────────────────────────────────
#
# `agent:` is optional correlation identity for the caller — a content digest
# plus an optional display name/version. The oracle never inspects it; it just
# rides along into the decision record for audit trails to pick up later.
{:ok, descriptor} =
  Mimir.Descriptor.parse(%{
    task_class: "extraction",
    budget_ceiling_microdollars: 50_000,
    latency_tolerance_ms: 30_000,
    expected_tokens: %{in: 2_000, out: 500},
    capabilities: [:tools],
    agent: %{digest: "sha256:9f2c...a01", name: "invoice-extractor", version: "1.4.0"}
  })

IO.puts("descriptor parsed for agent #{descriptor.agent.name} v#{descriptor.agent.version}")

# ── 3. Assemble the degenerate snapshot ──────────────────────────────────────
#
# `Mimir.Snapshot.assemble([])` with no options is the "degenerate" snapshot:
# every lane reports healthy (empty health map), pricing comes from the config
# above, and budget is unlimited (no `parent_remaining` ceiling from a fleet).
# This is what gateway-less mode looks like — there is no `Mimir.Health`
# GenServer running, no live budget source, so you hand the oracle nothing and
# it assumes the best. Wire in real `:health` / `:parent_remaining` opts once
# you have somewhere to source them from.
snapshot = Mimir.Snapshot.assemble([])

# ── 4. Ask the oracle for a placement ────────────────────────────────────────
#
# `Policy{}` with no `allowed_models` means no policy-level restriction beyond
# what the descriptor and snapshot already filter on.
case Mimir.Oracle.decide(descriptor, Mimir.Catalog.entries(), %Mimir.Oracle.Policy{}, snapshot) do
  {:placement, placement} ->
    IO.puts("\nplacement: #{placement.entry.id} (#{placement.entry.model})")
    IO.puts("reasons:   #{Enum.join(placement.reasons, ", ")}")

    # `grant_id` is nil here on purpose: a grant is a minted key's UUID, and
    # minting keys is the embedder's job (typically a fleet-scale gateway).
    # Gateway-less mode has no fleet, so there is nothing to mint against —
    # the decision record says so plainly rather than faking an id.
    record =
      Mimir.DecisionRecord.build(
        descriptor,
        {:placement, placement},
        nil,
        %{workflow_id: "wf_demo_001", step_id: "step_extract"},
        snapshot
      )

    IO.puts("\ndecision record (grant_id is nil — no fleet, no minted key):")
    IO.inspect(record, pretty: true)

  {:no_candidate, reasons, _candidates} ->
    IO.puts("\nno_candidate: #{inspect(reasons)}")
end

# ── 5. A descriptor the catalog can't satisfy ────────────────────────────────
#
# Two ways to force `:no_candidate`: an impossibly tight budget, or every lane
# reporting degraded via the snapshot's `:health` map. This one uses health —
# in a running fleet this map comes from `Mimir.Health.all/0`; it's inlined
# here since there's no GenServer running in this script.
all_degraded_snapshot =
  Mimir.Snapshot.assemble(
    health: %{"local" => :degraded, "anthropic" => :degraded, "anthropic-premium" => :degraded}
  )

case Mimir.Oracle.decide(
       descriptor,
       Mimir.Catalog.entries(),
       %Mimir.Oracle.Policy{},
       all_degraded_snapshot
     ) do
  {:placement, placement} ->
    IO.puts("\n(unexpected) placement: #{placement.entry.id}")

  {:no_candidate, reasons, candidates} ->
    IO.puts("\nno_candidate (all lanes degraded): #{inspect(reasons)}")
    IO.puts("per-entry verdicts:")
    Enum.each(candidates, &IO.inspect(&1, label: "  "))
end

# A budget too tight to clear even the cheapest priced entry tells the same
# story through the cost filter instead of health — `local-qwen` has no
# pricing entry (defaults to zero cost) so it's excluded on capability here
# instead, to keep both filters visible in one run.
{:ok, tight_descriptor} =
  Mimir.Descriptor.parse(%{
    task_class: "extraction",
    budget_ceiling_microdollars: 1,
    latency_tolerance_ms: 30_000,
    expected_tokens: %{in: 2_000, out: 500},
    capabilities: [:tools, :vision, :long_context]
  })

case Mimir.Oracle.decide(
       tight_descriptor,
       Mimir.Catalog.entries(),
       %Mimir.Oracle.Policy{},
       snapshot
     ) do
  {:placement, placement} ->
    IO.puts("\n(unexpected) placement: #{placement.entry.id}")

  {:no_candidate, reasons, _candidates} ->
    IO.puts("\nno_candidate (tight budget + missing capabilities): #{inspect(reasons)}")
end

# ── What's not here yet ──────────────────────────────────────────────────────
#
# This example never enforces a budget — it only ever *decides*, then trusts
# the caller to honor the decision. Budget guards that work without a fleet
# behind them (no minted keys, no router service) arrive with `Mimir.Guard` in
# 0.2.0. Until then, gateway-less mode is decision-only: pair it with your own
# accounting if you need hard spend limits.
IO.puts("\ndone — gateway-less mode: no service, no minted key, just the oracle.")
