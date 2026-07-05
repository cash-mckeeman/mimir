# Mimir

Mimir is an embeddable routing oracle, pricing source, and decision
vocabulary for LLM workloads. You consult it in-process: hand it a workload
descriptor and an operational snapshot, and it hands back a placement (or a
reasoned no-candidate answer) plus an auditable decision record. A gateway
service built on top of Mimir is one possible embedder — not a requirement.
A single application can link the library directly and route its own calls
with no service in between.

The name is a nod to the consulted head: every carrier embeds the same
oracle. The well it drinks from — metered access, minted keys, fleet state —
is the embedder's business, not this library's.

## Installation

Add `mimir` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mimir, "~> 0.1.0"}
  ]
end
```

## Module inventory

| Module | What it does |
| --- | --- |
| `Mimir.Descriptor` | Validated workload descriptor — the contract a workflow step presents to the oracle. |
| `Mimir.Oracle` | Pure filter-then-rank placement decision over catalog entries. |
| `Mimir.Catalog` | Config-sourced routable entries, with an injectable model resolver seam. |
| `Mimir.Snapshot` | Explicit-inputs operational snapshot the oracle ranks against (pricing, health, budget). |
| `Mimir.Health` | Failure-streak table for router lanes, driven by telemetry. |
| `Mimir.DecisionRecord` | Pure builder for a binary-keyed routing-decision audit record. |
| `Mimir.RouteLog` | Typed route outcome plus a request-log meta builder. |
| `Mimir.Pricing` | Token usage to integer microdollar cost, config-first over a vendored LiteLLM pricing DB. |
| `Mimir.TurnEvents` | Per-request ordered `gen_ai.*` event buffer. |
| `Mimir.RouterClient` | Behaviour for routing clients, with an HTTP (Req-based) implementation. |
| `Mimir.Redact` | Secret masking and payload-capture gating helpers. |

## Design rules

Mimir has no dependency on any agent-runtime or LLM client library. It does
not call models, does not manage conversation state, and does not mint or
verify auth. Governance — budget enforcement, key issuance, multi-tenant
isolation — composes in the embedder, on top of the plain data Mimir returns.

## Supervision

`Mimir.Health` and `Mimir.TurnEvents` are `GenServer`s that own ETS tables.
Add the ones you use to your application's supervision tree:

```elixir
children = [
  Mimir.Health,
  Mimir.TurnEvents
]
```

Everything else in the library (`Descriptor`, `Oracle`, `Catalog`,
`Snapshot`, `DecisionRecord`, `RouteLog`, `Pricing`, `RouterClient`,
`Redact`) is stateless — no process, no supervision needed.

## Configuration reference

All configuration lives under the `:mimir` application:

| Key | Used by | Meaning |
| --- | --- | --- |
| `:catalog` | `Mimir.Catalog` | List of routable entry configs (`id`, `model`, `lane`, `runtime`, ...). |
| `:pricing` | `Mimir.Pricing`, `Mimir.Snapshot` | Config-table token rates, `"provider:model" => %{input:, output:}`. Wins over the vendored DB. |
| `:pricing_db_path` | `Mimir.Pricing` | Override path to the vendored pricing DB (useful in tests). |
| `:health_threshold` | `Mimir.Health` | Failure-streak count at which a lane is reported `:degraded`. Default `3`. |
| `:completion_event` | `Mimir.Health` | Telemetry event `Health.attach/0` listens on. Default `[:mimir, :completion]`. |
| `:turn_events_tables` | `Mimir.TurnEvents` | `{seq_table, buf_table}` ETS table names, for running more than one buffer instance. |

## Development

- `mix quality` — format check, `--warnings-as-errors` compile, `credo --strict`, dialyzer.
- `mix mimir.smoke` — a staged end-to-end smoke of the public API: descriptor,
  catalog, oracle, decision record, route log, pricing, health, turn events,
  router client, and redact. It runs 10 stages; the router-client (HTTP)
  stage exercises a real request against an in-process plug under
  `MIX_ENV=test` (or in CI), and reports `[SKIP]` honestly otherwise, since
  the Plug dependency it needs is test-only.
- `mix test` — the ExUnit suite.

## Gateway-less mode

A single-app deployment embeds the library directly — no routing service, no
minted keys, no fleet state:

```elixir
# config/config.exs
config :mimir, :catalog, [
  %{id: "local-qwen", model: "ollama:qwen3", lane: "local", runtime: "local", priority: 10},
  %{id: "claude", model: "anthropic:claude-sonnet-4-6", lane: "anthropic", runtime: "managed"}
]

config :mimir, :pricing, %{
  "anthropic:claude-sonnet-4-6" => %{input: 3_000_000, output: 15_000_000}
}

# at the call site
{:ok, descriptor} =
  Mimir.Descriptor.parse(%{
    task_class: "extraction",
    budget_ceiling_microdollars: 50_000,
    latency_tolerance_ms: 30_000
  })

snapshot = Mimir.Snapshot.assemble([])   # degenerate: all lanes healthy, config pricing

case Mimir.Oracle.decide(descriptor, Mimir.Catalog.entries(), %Mimir.Oracle.Policy{}, snapshot) do
  {:placement, placement} -> run_step_on(placement.entry)
  {:no_candidate, reasons, _candidates} -> handle_no_candidate(reasons)
end
```

Same descriptors, same decision records, no service required. Budget guards
without minted keys arrive with `Mimir.Guard` in 0.2.0.

## Documentation

Full API docs are published on [HexDocs](https://hexdocs.pm/mimir) once
released, and can be generated locally with `mix docs`.

## License

Apache-2.0. See [LICENSE](LICENSE).
