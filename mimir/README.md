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
    {:mimir, "~> 0.8.0"}
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
| `Mimir.Pricing.Input`, `Mimir.Pricing.Quote` | Validated measurements and a quote that distinguishes priced, unpriced and incomplete usage. |
| `Mimir.Event` | Domain-typed event vocabulary (`llm.*` / `agent.*` / `workflow.*`) — the vocabulary root `Mimir.TurnEvents` buffers and `Mimir.Ingest` promotes raw events onto. |
| `Mimir.Event.OTel` | Canonical OTel GenAI semantic-convention rendering for `Mimir.Event` at the export edge — the one place that vocabulary still lives, on purpose. |
| `Mimir.CloudEvent` | CloudEvents v1.0 envelope — wraps any domain body (a `Mimir.Event` wire map, a decision record) in `data` with the standard context attributes as siblings. The second export edge. |
| `Mimir.CloudEvent.Types` | The `ai.bizinsights.mimir.*` CloudEvents `type` taxonomy — one home for the namespace, so producers never hand-assemble a type string. |
| `Mimir.TurnEvents` | Per-request ordered `Mimir.Event` buffer; the buffer, not the caller, owns `seq`/`ts`. |
| `Mimir.RouterClient` | Behaviour for routing clients, with an HTTP (Req-based) implementation. Returns a parsed `%Mimir.RouteResponse{}`. |
| `Mimir.RouteResponse` | Parsed routing-call result; `new/1` is the single boundary from wire map to struct. |
| `Mimir.Grant` | Minted routing grant: key, budget, expiry. |
| `Mimir.Placement` | Flat chosen-model placement: lane, model, runtime. |
| `Mimir.Binding` | A route decision prepared for execution: target compatibility, `model_config`, grant guard and correlation for a runtime adapter. |
| `Mimir.Binding.Target` | A host's statement of its execution target: runtime label, configured model, per-run-model and data-plane support. |
| `Mimir.Candidate` | One catalog entry's routing verdict: chosen, ranked, or excluded. |
| `Mimir.Redact` | Secret masking and payload-capture gating helpers. |
| `Mimir.Guard` | Turn-guard builders for a session's between-turn hook — grant-budget halts and mimir-less caps. |
| `Mimir.Ingest` | Decision-correlated ingestion of raw session events, promoted to `Mimir.Event` and appended to `Mimir.TurnEvents`. |

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
| `:pricing` | `Mimir.Pricing`, `Mimir.Snapshot` | Config-table token rates in µ$ per million tokens, `"provider:model" => %{input:, output:}`, with optional `cache_read:` and `cache_write:`. Each rate set here wins over the vendored DB's for that model; a rate left out comes from the DB. |
| `:pricing_db_path` | `Mimir.Pricing` | Override path to the vendored pricing DB (useful in tests). |
| `:health_threshold` | `Mimir.Health` | Failure-streak count at which a lane is reported `:degraded`. Default `3`. |
| `:completion_event` | `Mimir.Health` | Telemetry event `Health.attach/0` listens on. Default `[:mimir, :completion]`. |
| `:turn_events_tables` | `Mimir.TurnEvents` | `{seq_table, buf_table}` ETS table names, for running more than one buffer instance. |

## Pricing quotes

Use `Mimir.Pricing.quote/2` when callers need to distinguish known cost from
missing measurements or unavailable prices. An input is complete enough to
price only when all four counts are known, `input_token_basis` is `:inclusive`
or `:uncached`, `complete?` is `true` and `in_flight` is `:none`.
Inclusive input includes both cache categories; uncached input excludes them.
Incomplete and unpriced quotes have `nil` cost; unknown facts never imply zero.

```elixir
alias Mimir.Pricing
alias Mimir.Pricing.{Input, Quote}

Application.put_env(:mimir, :pricing, %{"example:free" => %{input: 0, output: 0}})

attrs = %{
  input_tokens: 12,
  output_tokens: 5,
  cache_read_input_tokens: 0,
  cache_creation_input_tokens: 0,
  input_token_basis: :uncached,
  complete?: true,
  in_flight: :none
}

{:ok, input} = Input.new(attrs)
{:ok, %Quote{status: :priced, cost_microdollars: 0}} = Pricing.quote("example:free", input)

{:ok, incomplete} = Input.new(Map.delete(attrs, :cache_read_input_tokens))

{:ok, %Quote{status: :incomplete, cost_microdollars: nil}} =
  Pricing.quote("example:free", incomplete)

case Pricing.quote("example:free", input) do
  {:ok, %Quote{status: :priced, cost_microdollars: cost}} ->
    {:known_cost, cost}

  {:ok, %Quote{status: status}} when status in [:incomplete, :unpriced] ->
    {:unknown_cost, status}

  {:error, reason} ->
    {:error, reason}
end
```

See `Mimir.Pricing.quote/2` for rate availability and tagged configuration
errors, and `Mimir.Pricing.Input.new/1` for validation and omission defaults.
The compatible `Mimir.Pricing.cost_microdollars/2` API defaults missing usage
and unknown base rates to zero, and uses the input rate when a cache rate is
missing. `Mimir.Guard` continues to use that API for its soft budget threshold.

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

Everything downstream — `Mimir.Binding.new/2`, `Mimir.Guard.for_grant/3`,
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

To correlate raw session events back to the routing decision for metering,
call `Mimir.Ingest.handle_event/2` from your session handler's event hook;
drain the buffered, correlated `%Mimir.Event{}` list with
`Mimir.TurnEvents.take/1` when you meter the run.

## Event vocabulary

`Mimir.Event` is the domain-typed vocabulary root for everything that
travels the `llm.* / agent.* / workflow.*` streams — LLM turns, agent-session
lifecycle, and workflow steps each get their own closed `type` union under a
`domain`, instead of one untyped junk-drawer payload. Build one with
`Event.llm/2`, `Event.agent/2`, or `Event.workflow/2`; `Event.to_wire/1` /
`Event.from_wire/1` are the struct-in-BEAM / JSON-at-the-boundary pair —
`to_wire/1` is exactly the shape a caller should persist.

`Mimir.TurnEvents.append/2` stores a `%Mimir.Event{}` under a request id; the
buffer — not the caller — owns `seq`/`ts`, stamping both at append time.
`Mimir.TurnEvents.take/1` returns the buffered events in that
buffer-assigned order.

The OpenTelemetry GenAI semantic-convention vocabulary (`gen_ai.*`) is not a
domain concept here — it is one export-edge rendering, owned by
`Mimir.Event.OTel.render/1`. Only that module renders `gen_ai.*` attributes;
everything upstream of it works in typed `Mimir.Event` domains.

`Mimir.CloudEvent` is the second export edge, on the same principle. A
CloudEvents v1.0 envelope wraps a domain body in `data` and carries the standard
context attributes — `id`, `source`, `type`, `time` — alongside it.
`Mimir.Event` is deliberately unchanged by this: it has no `id`/`source` and its
`ts` is monotonic rather than wall-clock, so it becomes the *body* of a
CloudEvent, never a CloudEvent itself.

```elixir
{:ok, ce} =
  Mimir.CloudEvent.from_event(event,
    id: "req_1:2",
    source: "//mimir.bizinsights.ai/gateway/prod-1",
    time: "2026-07-25T14:01:10.123Z"
  )

Mimir.CloudEvent.to_wire(ce)
#=> %{"specversion" => "1.0", "type" => "ai.bizinsights.mimir.llm.tool_call",
#=>   "data" => %{"domain" => "llm", ...}, ...}
```

The `id`, `source`, and `time` a CloudEvent needs are supplied by the *producer*
that wraps the body — `from_event/2` validates their shape and invents none of
them. Type strings come from `Mimir.CloudEvent.Types`, never hand-assembled.
Construction is strict; `from_wire/1` is tolerant and never raises, carrying an
unknown extension attribute through rather than dropping it.

## Documentation

Full API docs are published on [HexDocs](https://hexdocs.pm/mimir) once
released, and can be generated locally with `mix docs`.

## License

Apache-2.0. See [LICENSE](LICENSE).
