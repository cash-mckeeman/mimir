# Changelog

## 0.4.1 (2026-07-17)

Additive provenance field: `Mimir.Event` gains `path`, a materialized call
path — an ordered list of `"<kind>:<id>"` frames (closed kind union
`workflow | workflow_step | agent | conversation`) naming the chain of scopes
that **contain** the event, outermost first, innermost last, defaulting to
`[]`. One event, in isolation, recreates its full containment lineage;
`List.last(path)` is the innermost scope the event belongs to (for a leaf
event, its immediate container; for a scope-lifecycle event, the scope
itself). This is deliberately the **containment/spawn axis** ("what scopes am
I inside"), distinct from any data-dependency axis a caller tracks separately
("whose output did I consume") — the two can diverge and this field only
carries the former. `llm/2`/`agent/2`/`workflow/2` validate every frame
against the closed kind set (bad kind or empty id → `{:error, {:bad_frame,
frame}}`) — construction only ever writes known kinds. `to_wire/1` includes
`"path"` only when non-empty. `from_wire/1` treats `path` as
malformed-optional data and validates **shape only** — a well-formed
`"kind:id"` pair, the kind NOT checked against the closed union — so an
unknown-but-well-formed kind from a newer producer passes through intact
(an additive kind is not a reader-breaking change); a missing key, a non-list,
or a genuinely malformed frame degrades the whole path to `[]` rather than
failing the parse. `Mimir.Event.OTel.render/1` adds a `"mimir.path"` attribute
(frames joined with `/`) when `path != []`; the frozen `gen_ai.*` byte-compat
goldens are unaffected since none of those fixtures carry a path.

## 0.4.0 (2026-07-16)

Replaces the `gen_ai` junk-drawer envelope with a domain-typed event
vocabulary. `gen_ai` is demoted to what it always should have been: a wire
format at the OTel export edge, not a domain model.

- `Mimir.Event` — the new vocabulary root: a closed `domain`
  (`:llm | :agent | :workflow`) × `type` union, typed correlation ids
  (`request_id`, `workflow_id`, `step_id`, `session_id` — the correlation
  spine is unchanged, just promoted to typed fields), promoted `usage`/
  `tool` commons, and a `raw` carve-out for anything provider-specific.
  `Event.llm/2`, `Event.agent/2`, `Event.workflow/2` build it;
  `Event.to_wire/1` / `Event.from_wire/1` are the struct-in-BEAM /
  JSON-at-the-boundary pair — `to_wire/1` is the shape downstream storage
  should persist.
- `Mimir.Event.OTel` — the one canonical OTel-attribute mapper for the
  export edge. `llm.*` reproduces the retired `Mimir.TurnEvents.GenAI`
  helpers' attribute names byte-for-byte (`gen_ai.usage.input_tokens`,
  `gen_ai.tool.name`, `gen_ai.tool.call.id`, the bare `milestone` reasoning
  marker); `agent.*` renders OTel GenAI *agent* semconv
  (`gen_ai.operation.name=invoke_agent`, `gen_ai.conversation.id`);
  `workflow.*` is plain `mimir.workflow.*` — no GenAI pretense.
- `Mimir.TurnEvents` is rewritten around `Mimir.Event`: `append/2` takes
  `rid` and an `%Event{}` — the buffer, not the caller, owns `seq`/`ts`,
  overwriting whatever the caller's constructor set. `take/1`/
  `take_current/0` return `[%Event{}]` in buffer-assigned seq order.
- `Mimir.Ingest` promotes every ingested raw provider map to a `%Event{}`
  (domain `:llm`) before buffering. `metadata`'s `"workflow_id"`/
  `"step_id"` keys are unchanged, now threading into the event's typed
  `workflow_id`/`step_id` fields instead of a loose payload merge.
- `Mimir.RouteLog.to_meta/2`'s meta key is renamed `gen_ai_events` →
  `turn_events` (matching the persisted column name the gateway migrates to
  next); its one entry's payload key is renamed `"gen_ai"` → `"decision"`.
  Routing decisions still never enter the `Mimir.Event` vocabulary —
  `DecisionRecord`/`RouteLog` keep their own audit shape, by design.

### BREAKING

This is a big-bang rename — no deprecation shims, no dual shapes:

- `Mimir.TurnEvents`'s old `append/3` (`rid, type, gen_ai_map`) is replaced
  by `append/2` (`rid, %Mimir.Event{}`); the old `append_current/2` is
  replaced by `append_current/1` (`%Mimir.Event{}`).
- `Mimir.TurnEvents.take/1` / `take_current/0` now return `[%Mimir.Event{}]`,
  not `[%{"seq" => _, "ts" => _, "type" => _, "gen_ai" => map()}]`.
- `Mimir.TurnEvents`'s `envelope/4` is removed.
- `Mimir.TurnEvents.GenAI` is removed. Its three builders (`reasoning/1`,
  `tool_use/1`, `usage/2`) have no drop-in replacement — build a
  `Mimir.Event` instead, and render it at the export edge with
  `Mimir.Event.OTel.render/1` if you need the old attribute shapes.
- `Mimir.RouteLog.to_meta/2`'s meta map key `gen_ai_events` is renamed
  `turn_events`; its entry's `"gen_ai"` key is renamed `"decision"`.

**Migration:** if you persist the old envelope shape
(`%{"seq" => _, "ts" => _, "type" => _, "gen_ai" => map()}`), adopt
`Mimir.Event.to_wire/1` / `Mimir.Event.from_wire/1` as the new persisted
form — `to_wire/1` is exactly what downstream storage should write instead.
The `mimir_gateway` 0.4.0-line release is the reference migration for this:
its `request_log.gen_ai_events` → `turn_events` backfill transforms every
existing row from the old envelope into `Event.to_wire/1`'s shape in place,
row by row, inside the migration transaction — that transformer is the
worked example to copy for any other store still holding the old shape.

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
