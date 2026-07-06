# Changelog

## 0.3.0 (2026-07-06)

Replaces the routing layer's bare-map vocabulary with typed structs, parsed at
a single boundary.

- `Mimir.RouteResponse` — the parsed result of a routing call, with `new/1` as
  the single boundary where a decoded (atom- or string-keyed) wire response
  becomes mimir's struct vocabulary. `c:Mimir.RouterClient.route/2` now returns
  `{:ok, %RouteResponse{}}` directly — no ad-hoc atomization downstream.
- `Mimir.Grant`, `Mimir.Placement`, `Mimir.Candidate` — the leaf structs
  `RouteResponse.new/1` parses onto: a minted grant (key, budget, expiry), the
  flat chosen-model placement (lane, model, runtime), and one catalog entry's
  routing verdict (chosen, ranked, or excluded).
- `Mimir.Oracle.Placement` is renamed `Mimir.Oracle.Decision` — the rich
  server-side decision (entry, reasons, candidate verdict table), distinct
  from the wire-level `Mimir.Placement`.
- `Mimir.DecisionRecord` is now a struct (`build/5` returns a
  `%DecisionRecord{}`); `to_event/1` renders it to the binary-keyed audit map.
  The rendered turn-event shape is unchanged.

### BREAKING

- `c:Mimir.RouterClient.route/2` returns `{:ok, %Mimir.RouteResponse{}}` instead
  of `{:ok, map()}`.
- `Mimir.DecisionRecord.build/5` returns a `%Mimir.DecisionRecord{}` instead of
  a plain map; its `verdict` argument is now `{:decision, %Oracle.Decision{}}`
  (was `{:placement, %Oracle.Placement{}}`).
- `Mimir.Oracle.decide/4` returns `{:decision, %Oracle.Decision{}}` instead of
  `{:placement, %Oracle.Placement{}}`.
- `Mimir.Guard.for_grant/3` now takes a `%Mimir.Grant{}` instead of a plain
  grant map. `Mimir.Sessions.opts/2` and `Mimir.Ingest.from_route/2` now take
  a `%Mimir.RouteResponse{}` instead of a raw route response map.

## 0.2.0 (2026-07-05)

Adds a governance composition layer on top of the routing oracle:
`Mimir.Guard`, `Mimir.Ingest`, `Mimir.Sessions`.

- `Mimir.Guard` — turn-guard builders for a session loop's between-turn hook.
  `for_grant/3` prices the session's accumulated usage against a route
  response's grant and halts on budget; `caps/1` is the mimir-less form
  (turn/token/cost caps, no minted key). Guards never raise mid-run: a
  pricing-table miss degrades to whatever caps remain and emits a
  `[:mimir, :guard, :pricing_miss]` telemetry event (once per process per
  model).
- `Mimir.Ingest` — decision-correlated ingestion of raw session events into
  `Mimir.TurnEvents`, keyed by request id with the routing decision's
  correlation merged into each event's gen_ai map.
- `Mimir.Sessions` — the canonical recipe: `opts/2` turns a route response
  into a `model_config` (granted key plus routed `base_url`), a
  `turn_guard`, and `telemetry_metadata`, ready to splice into a session run.

These three target the documented hook contract of `req_managed_agents`
0.5.0+ by data shape only — the `turn_guard` payload shape and the synthetic
`"rma.text_delta"` event — with no code dependency on that library.
`model_config.api_key` threading is a harmless opaque passthrough on 0.5.0+
runtimes and activates fully as the enforced grant key once the embedder is
on `req_managed_agents` 0.6.0.

Also: two new `mix mimir.smoke` stages (guard, sessions) covering the
composition layer end-to-end.

## 0.1.0 (2026-07-04)

Initial release.

Modules: `Mimir.Descriptor`, `Mimir.Oracle`, `Mimir.Catalog`, `Mimir.Snapshot`,
`Mimir.Health`, `Mimir.DecisionRecord`, `Mimir.RouteLog`, `Mimir.Pricing`,
`Mimir.TurnEvents`, `Mimir.RouterClient` (with an HTTP implementation), and
`Mimir.Redact`.

Design seams as features:

- Injectable model resolver in `Mimir.Catalog` — validate or enrich catalog
  entries through your own registry without touching the oracle.
- Explicit-inputs `Mimir.Snapshot` — the oracle only ever sees a snapshot the
  embedder assembled; no hidden reads of process state or global config.
- Embedder-owned persistence — decision records and route logs are plain
  data; whether and how they're stored is entirely the embedder's call.

Also: a `mix mimir.smoke` task that drives the public API end-to-end as a
repeatable, CI-asserted smoke check, and a `mix quality` alias (format check,
warnings-as-errors compile, credo, dialyzer) for local and CI use.
