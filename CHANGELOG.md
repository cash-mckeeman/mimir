# Changelog

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
