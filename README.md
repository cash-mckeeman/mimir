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
    {:mimir, "~> 0.3.0"}
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
| `Mimir.DecisionRecord` | Typed routing-decision record; `to_event/1` renders the binary-keyed audit map. |
| `Mimir.RouteLog` | Typed route outcome plus a request-log meta builder. |
| `Mimir.Pricing` | Token usage to integer microdollar cost, config-first over a vendored LiteLLM pricing DB. |
| `Mimir.TurnEvents` | Per-request ordered `gen_ai.*` event buffer. |
| `Mimir.RouterClient` | Behaviour for routing clients, with an HTTP (Req-based) implementation. Returns a parsed `%Mimir.RouteResponse{}`. |
| `Mimir.RouteResponse` | Parsed routing-call result; `new/1` is the single boundary from wire map to struct. |
| `Mimir.Grant` | Minted routing grant: key, budget, expiry. |
| `Mimir.Placement` | Flat chosen-model placement: lane, model, runtime. |
| `Mimir.Candidate` | One catalog entry's routing verdict: chosen, ranked, or excluded. |
| `Mimir.Redact` | Secret masking and payload-capture gating helpers. |
| `Mimir.Guard` | Turn-guard builders for a session's between-turn hook — grant-budget halts and mimir-less caps. |
| `Mimir.Ingest` | Decision-correlated ingestion of raw session events into `Mimir.TurnEvents`. |
| `Mimir.Sessions` | Canonical recipe: route response to session options (`model_config`, `turn_guard`, `telemetry_metadata`). |

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
| `:gateway_base_url` | `Mimir.Sessions` | Default `:base_url` for `opts/2`'s `model_config`, when not passed explicitly. |

## Examples

Runnable, heavily-commented examples ship with the package:

- [`examples/gateway_less.exs`](examples/gateway_less.exs) — the headline
  pattern: consult the oracle in-process, no service required. Configures a
  catalog and pricing in-script, parses a descriptor, assembles the
  degenerate snapshot, and prints both a placement's decision record and a
  couple of `no_candidate` outcomes.
- [`examples/routed_grants.exs`](examples/routed_grants.exs) — the fleet
  shape: route through a live router service via `Mimir.RouterClient.HTTP`,
  print the placement and masked grant, and handle `no_candidate` and error
  responses. Prints friendly setup instructions and exits cleanly if
  `ROUTER_URL`/`ROUTER_KEY` aren't set.

## Development

- `mix quality` — format check, `--warnings-as-errors` compile, `credo --strict`, dialyzer.
- `mix mimir.smoke` — a staged end-to-end smoke of the public API: descriptor,
  catalog, oracle, decision record, route log, pricing, health, turn events,
  router client, redact, guard, and sessions. It runs 12 stages; the
  router-client (HTTP) stage exercises a real request against an in-process
  plug under `MIX_ENV=test` (or in CI), and reports `[SKIP]` honestly
  otherwise, since the Plug dependency it needs is test-only.
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
  {:decision, decision} -> run_step_on(decision.entry)
  {:no_candidate, reasons, _candidates} -> handle_no_candidate(reasons)
end
```

Same descriptors, same decision records, no service required. Budget guards
without minted keys are plain caps, no grant needed:

```elixir
turn_guard = Mimir.Guard.caps(max_cost_microdollars: 50_000, model: "anthropic:claude-sonnet-4-6")
```

See [Governance composition](#governance-composition) below for the grant-backed
form and the rest of the composition layer.

## Routing vocabulary

`c:Mimir.RouterClient.route/2` returns `{:ok, %Mimir.RouteResponse{}}` — a
parsed struct, never a raw map. `RouteResponse.new/1` is the single boundary
where a decoded wire response becomes mimir's struct vocabulary:

- `Mimir.RouteResponse` — the top-level parsed result: `verdict`
  (`:placement | :no_candidate`), the chosen `placement` and `grant` (if
  any), and the candidate verdict table.
- `Mimir.Placement` — the flat chosen-model placement: `lane`, `model`,
  `runtime`.
- `Mimir.Grant` — the minted routing grant: `key`, `budget_microdollars`,
  `expires_at`.
- `Mimir.Candidate` — one catalog entry's verdict: `:chosen`, `:ranked`, or
  `{:excluded, reason}`.

Everything downstream — `Mimir.Sessions.opts/2`, `Mimir.Guard.for_grant/3`,
`Mimir.Ingest.from_route/2` — consumes these structs directly; none of them
touch a raw route map.

## Governance composition

Mimir hands back plain data — a placement, a grant, a decision record.
Turning that into enforcement is the embedder's job, and it splits into two
planes:

- **Data plane** — the grant's minted key and the gateway's `base_url` ride
  along in `model_config`. For runtimes that route every call through the
  gateway, this is hard enforcement: the gateway itself refuses spend past
  the grant's budget.
- **Control plane** — `Mimir.Guard` builds a `turn_guard` function that prices
  a session's accumulated usage after each turn and halts once a cap is hit.
  This is the soft half, for runtimes the gateway can't sit in front of, or
  as defense in depth alongside the data plane.

`Mimir.Sessions.opts/2` is the canonical recipe that wires both planes from a
single route response:

```elixir
{:ok, resp} = Mimir.RouterClient.route(descriptor, client_opts)
# resp is a %Mimir.RouteResponse{} — see Routing vocabulary, above
session_opts = Mimir.Sessions.opts(resp, base_url: gateway_url)
Session.run(provider, session_opts ++ [handler: MyTools, prompt: prompt])
```

`opts/2` raises `ArgumentError` on a no-candidate or malformed route
response — fail at composition time, not mid-session. `Mimir.Guard` handles
the mid-run side and never raises.

To correlate raw session events back to the routing decision for metering,
call `Mimir.Ingest.handle_event/2` from your session handler's event hook;
drain the buffered, correlated events with `Mimir.TurnEvents.take/1` when you
meter the run.

## Documentation

Full API docs are published on [HexDocs](https://hexdocs.pm/mimir) once
released, and can be generated locally with `mix docs`.

## License

Apache-2.0. See [LICENSE](LICENSE).
