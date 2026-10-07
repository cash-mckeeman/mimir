# Changelog

## Unreleased

Tool results get their own event. `Mimir.Ingest` classifies a frame carrying a
binary `"tool_use_id"` as a new `llm` event, `:tool_result`, before it looks
for a named tool call. The event's `tool` holds the `tool_use_id` as `id` and
the frame's `"name"` as `name`, or `nil` when the frame has none; the
provider's payload stays in `raw`. Before, a named tool-result frame became a
second `:tool_call`, and an unnamed one was dropped as unrecognized.
`Mimir.Event`'s `tool.name` type admits `nil`. `Mimir.Event.from_wire/1` in an
earlier release returns
`{:error, {:bad_event, {:bad_type, :llm, "tool_result"}}}` for the new type.

mimir is now published from the `mimir/` directory of a repository shared with `mimir_workflows` and
`mimir_orchestration`; minor releases are shared across the three.

Dependency-direction tests guard the declared dependency sets and module references in `lib/`.

`Mimir.Event.OTel`'s documentation reflects the current GenAI conventions; output is unchanged.

## 0.6.1 (2026-10-02)

Refreshes the vendored LiteLLM pricing DB (`mix mimir.pricing.refresh`,
fetched 2026-10-02). It now prices `claude-opus-5-5`, `claude-sonnet-5-5`
and `claude-fable-5-1`, all absent from 0.6.0's vendored copy — a caller
pricing any of those three got `0` from `Mimir.Pricing.cost_microdollars/2`
before this release. Records removed upstream retain their last known vendored
rates so previously supported model IDs continue to price historical usage.
These retained rates are compatibility data, not a claim of current provider
availability or prices. Eight records whose upstream schemas no longer match
the token-price loader also retain their previous compatible token rates;
image-output-token fields are not interpreted as text-output-token prices.
The compatible refreshed records update 287 previously priced rate maps,
including 169 with input/output changes and 118 with cache-only changes.
The three new Claude IDs have regression checks for cache-read and cache-write
rates as well as positive input/output prices.

No rate changed for any previously-priced model
checked against the refresh (`claude-sonnet-4-6`, `gpt-4o`,
`claude-haiku-4-5`); upstream changed non-billing metadata around them.

## 0.6.0 (2026-10-02)

Cache-aware pricing. `Mimir.Pricing.cost_microdollars/2` prices cache read and
cache write tokens, and resolves each rate on its own, so a config entry no
longer hides the vendored DB's cache rates for the same model.

- **`usage` widens, additively.** `Mimir.Pricing.usage` gains optional
  `:cache_read_input_tokens` and `:cache_creation_input_tokens` (Anthropic's
  names, atom-keyed). A two-key `%{input_tokens:, output_tokens:}` map prices
  exactly as before. A caller holding a usage struct passes
  `Map.from_struct(usage)`. The two cache keys also tolerate an explicit
  `nil` value (priced as absent) — useful for a caller passing a decoded
  wire map straight through, where Anthropic's own cache counts can be
  `null`; `input_tokens`/`output_tokens` don't get the same tolerance.
- **Cache rates.** A config-table entry takes optional `cache_read:` and
  `cache_write:` (µ$ per million tokens). The vendored LiteLLM DB's
  `cache_read_input_token_cost` and `cache_creation_input_token_cost` are now
  read. Cache writes price at the single `cache_write` rate; LiteLLM's separate
  1-hour cache-write cost is not read.
- **Per-field resolution.** Each of `input`, `output`, `cache_read` and
  `cache_write` comes from the config entry when it sets that rate, else from
  the vendored DB. Before, a config entry won whole: an entry with only
  `input:`/`output:` hid the DB's cache rates, and an entry missing `output:`
  was ignored entirely. Now a config entry that overrides input and output (a
  negotiated rate, say) inherits the DB's list cache rates unless it sets its
  own, and a partial entry's rates are used for the fields it sets.
- **The oracle resolves a partial pricing entry too, instead of
  crashing.** 0.5.0's oracle raised `MatchError` the moment a
  `Mimir.Snapshot`'s own `:pricing` table held an entry missing `input:`
  or `output:`, as soon as ranking needed a cost projection. A snapshot's
  pricing entry can be partial the same way a config entry can; the
  oracle now resolves it the same way too, instead of requiring every
  entry to be complete.
- **Never free by default.** With no cache rate from either source, cache
  tokens price at the model's input rate rather than at zero, and
  `[:mimir, :pricing, :no_cache_rate]` fires, with the token counts priced
  that way as measurements and `%{model: model}` as metadata. (An unpriced
  model's input rate is already 0, so its cache tokens cost 0 too, as
  before.) It fires only when such tokens are present. A zero cache cost in
  the vendored DB counts as no rate.
- **Types.** New `Mimir.Pricing.rates`. `Mimir.Snapshot.rates` now refers to
  it, so it widens to admit the optional cache rates; the oracle still ranks
  on `input` and `output` only.
- **The oracle resolves a snapshot's missing pricing entries from the
  vendored DB too, not only zero.** A model absent from a snapshot's
  `:pricing` table previously ranked as free — `0` input/output, always
  cheapest. It now resolves the same way `Mimir.Pricing` does: the vendored
  DB's list rate when there is one, zero only when there is neither a
  config entry nor a DB entry. **This can change which candidate a snapshot
  with an incomplete pricing table ranks cheapest** — a DB-priced model
  that was accidentally priced free no longer beats a genuinely cheaper
  one. **It can also change whether a routing call decides at all.** A
  candidate missing from the pricing table used to pass any budget
  ceiling for free; now its projected cost is priced for real, so a call
  that returned a decision before can come back `{:no_candidate, [:cost],
  …}` instead, if that candidate's real cost is over the ceiling (or the
  caller's remaining budget) and no other candidate is viable. Keep a
  snapshot's `:pricing` table complete, or rely on the DB fallback
  deliberately, for every candidate you want cost-ranked — and
  cost-filtered — honestly.
- **`Mimir.Guard` cost caps price cache tokens.** `for_grant/3`'s grant
  budget and `caps/1`'s `:max_cost_microdollars` now include
  `cache_read_input_tokens`/`cache_creation_input_tokens` in the priced
  cost, through the same usage map Guard prices through `Mimir.Pricing`.
  `:max_total_tokens` still counts `input_tokens` + `output_tokens` only.
  A `{:halt, {:budget_exceeded, %{usage: …}}}` now carries all 4 keys,
  not 2 — a caller matching the old 2-key shape needs to widen it.
- **A misconfigured pricing entry now raises, loudly, where 0.5.0 accepted
  it silently.** This covers both the `:mimir, :pricing` config table
  (through `Mimir.Pricing.cost_microdollars/2`) and a `Mimir.Snapshot`'s
  own `:pricing` table (`Mimir.Oracle` validates that table the same way,
  not by calling `cost_microdollars/2`). Either path raises
  `Mimir.Pricing.InvalidConfigError`, a dedicated exception (not a bare
  `ArgumentError`, so a caller can rescue this failure specifically
  without swallowing an unrelated one), for: a rate that isn't a
  non-negative integer (0.5.0's `Mimir.Pricing` already raised on a float,
  in `div/2`; so did the oracle, but only when a cost projection was
  computed — without one, 0.5.0's oracle compared the float as-is and
  still decided, so this is new on that path); a negative rate (0.5.0
  used it directly, pricing silently negative); and a key outside
  `input:`/`output:`/`cache_read:`/
  `cache_write:` (0.5.0's `%{input:, output:}` match ignored any extra
  key in the map — a stray `currency:` field, say — and now raises
  instead). `Mimir.Guard` rescues this specific exception and halts with
  `{:invalid_pricing, %{model:, usage:, message:}}` instead of raising
  mid-run; calling `Mimir.Pricing` directly still raises.
- No new runtime dependency.
- **Elixir floor raised to 1.18.** `mix.exs` now requires `~> 1.18`. CI
  tests Elixir 1.18/OTP 27 and Elixir 1.20/OTP 29; Elixir 1.15 and OTP 26
  are no longer tested, and mimir may use syntax or stdlib features from
  1.18 in a future release.

## 0.5.0 (2026-07-25)

Adds `Mimir.CloudEvent`, a CloudEvents v1.0 envelope, as the ecosystem's uniform
event wrapper. It carries any domain body — a `Mimir.Event` wire map, a routing
decision record, a metering record — in `data`, with the CloudEvents context
attributes as siblings. **`Mimir.Event` is unchanged**: it has no
`id`/`source`/`specversion` and its `ts` is monotonic rather than wall-clock, so
CloudEvents is an envelope concern here, a second export edge alongside
`Mimir.Event.OTel` — not a rewrite of the vocabulary root.

- `Mimir.CloudEvent` — struct plus strict `new/1`, `from_event/2` (wraps a
  `Mimir.Event`, taking `type` from the taxonomy and `data` from
  `Event.to_wire/1`), `to_wire/1`, tolerant `from_wire/1`, and `valid_time?/1`.
  `@enforce_keys [:id, :source, :type]`. The `id`/`source`/`time` a CloudEvent
  needs are supplied by the **producer** that wraps a body; this module
  validates their shape and invents none of them.
- `Mimir.CloudEvent.Types` — the `ai.bizinsights.mimir.*` `type` taxonomy.
  `for_event/1` derives `ai.bizinsights.mimir.<domain>.<type>` from a
  `Mimir.Event`; one helper per record family. Open, not a closed union: a
  broker or consumer must never reject an unknown or newer `type`.
  `memory/1` is explicitly **provisional** — no producer implements that
  vocabulary yet.
- `data` is **any JSON value**, carried verbatim and never interpreted here;
  consumers decode per `type`. A binary body travels base64-encoded in
  `data_base64` instead, and the two are mutually exclusive — `new/1` rejects
  being handed both.
- `dataschema` and **extension attributes** are modeled. `from_wire/1` preserves
  every unrecognized top-level string key as an extension and `to_wire/1` merges
  them back at the top level, so distributed-tracing context
  (`traceparent`/`tracestate`) and broker-specific attributes survive a
  parse/render trip intact. An extension may not shadow a modeled attribute.
- Construction is strict, the wire is tolerant — the same posture as
  `Mimir.Event`. `new/1` requires non-empty `id`/`source`/`type`, validates
  `time`, honors a supplied `datacontenttype`, and rejects a `specversion` it
  cannot write. `from_wire/1` requires those four attributes and
  `specversion == "1.0"`, degrades malformed *optional hints* (`time`,
  `subject`, `dataschema`) to `nil`, never drops a body, and never raises.
- `valid_time?/1` documents where `DateTime.from_iso8601/1` diverges from
  RFC3339 (`-00:00`, lowercase `t`/`z`, leap seconds are rejected; a space
  separator is accepted) rather than claiming exactness — `new/1` hard-rejects
  on it.
- No new runtime dependency; the `~> 1.15` Elixir floor is unchanged.

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
