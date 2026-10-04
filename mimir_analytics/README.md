# mimir_analytics

Analytical run-record store for the mimir agent stack: the canonical,
queryable record of an agent run — workflow → step → run (session) → turn →
tool_call, plus model calls, routing decisions, eval outcomes, and raw
events — MotherDuck-hosted DuckLake in deployment, a local DuckDB file in
dev/test, fed by idempotent JSONL-buffered ingest.

## The correlation-id contract

Every mapper populates these columns, with exactly these names, whenever the
source carries them: `workflow_id`, `step_id`, `parent_step_id`, `run_id`,
`mimir_request_id`, `decision_id`, `grant_id`, `virtual_key_id`,
`parent_key_id`, `tenant_id`, `agent_digest`. A consumer joins any two
tables through the workflow/step/run spine without knowing which subsystem
captured the row. This contract — not the table list — is the stable part;
tables grow columns additively only.

### Why `mimir_request_id`, not `request_id`

Every other family repo calls this column `request_id`. Here it's
`mimir_request_id` on purpose: this store joins rows pulled from multiple
sources (gateway request logs, session drops, eval reports), and several of
those sources carry their own unrelated `request_id`-shaped column (e.g. the
gateway export's upstream `scope_id`/`request_id` pair). Namespacing the
mimir-side id avoids silent collisions/shadowing at mapper and query time.

## Dependency direction (invariant)

`mimir_analytics` depends on **nothing in-house** — no `Mimir.*`, no
`ManagedAgents.*`, no RMA types. Mappers take plain maps and file paths;
capture takes `Jason`-encodable data. Consumers dep on this library, never
the reverse. Grep-enforced by `test/mimir_analytics/dep_direction_test.exs`.

## Running the ingest

```sh
mix mimir_analytics.ingest \
  --db run_record.duckdb \
  --sessions path/to/session-drops \
  --gateway  path/to/gateway-pull-buffers \
  --evals    path/to/eval_runs
```

The gateway buffers come from `MimirAnalytics.Ingest.GatewayPull` (an
`updated_since`-cursor pull of the gateway's read-only Observability API);
sessions come from `MimirAnalytics.Capture.write/3` call sites in consumers;
eval reports are the harness's own JSON artifacts.

Every mapper is idempotent by file contents via `ingest_ledger`, which keys
each ingested file by the sha256 of its bytes, so re-running reads nothing
twice. A reused file name with new contents is ingested, except for an eval
report: reports are left in place, so a rewritten one is rejected rather
than adding its rows again.

The sessions directory is a spool: each file that ingests is moved into
`<sessions>/.ingested/`, which later runs never read. Gateway buffers and
eval reports are left in place.

An empty spool file can never be ingested. It is reported once and moved
into `<sessions>/.quarantined/`, next to a `<name>.reason` file saying why,
and later runs never read it there. To re-queue it, move it back into the
sessions directory.

An eval report that is empty, or that was rewritten after it was ingested,
is rejected but never moved, because other tools read the eval directory.
The rejection is recorded in `ingest_rejections` under the report's content
digest, with the reason, so it is reported once per distinct contents; a
further rewrite is reported again. To clear one, either restore the file to
the contents that were ingested, or accept the new version: delete its
`ingest_rejections` row, and the earlier version's `eval_outcomes` rows and
`ingest_ledger` row for that file name, then re-run the ingest.

A spool producer must publish each file by rename: write it once under a
dot-prefixed temporary name in the same directory, then rename it to its
final `*.jsonl` name. A visible `*.jsonl` file is then complete and never
changes, which is what makes moving it aside after the read safe. Ingest
cannot tell a file that is still being appended to from a finished one, so
a producer that appends to a published file loses whatever it appends after
that file is read.

## Upgrading a database

A database created before the ingest ledger was keyed by content holds
entries keyed by file name. Those cannot tell a file that grew after it was
read from one that was read in full, so `mix mimir_analytics.ingest` refuses
such a database. Rebuild it instead of migrating it:

1. Stop every writer that appends to a published spool file, and let the
   last daily file finish.
2. Delete the database (a local file, or `DROP DATABASE` on MotherDuck).
3. Re-run the ingest over the original source directories. Ingest before
   this change never moved files, so every source file is still in place,
   and each is read once, in full, into the new database.

## Adding a mapper

Fixture first: check a captured real payload into
`test/support/run_record_fixtures/`, write the test asserting exact rows,
then the mapper. The fixtures are the wire-shape alarm — when a source
changes shape, the diff against a fresh capture is the signal.

## Honest gap: managed runtimes

Managed-runtime sessions (provider-hosted loops) have no per-call
`model_calls` rows — their inner-loop calls never traverse the gateway.
`runs.cost_microdollars` is priced from usage upstream at capture; parity
comparisons run at session grain. Never synthesize per-call rows.

## One-time setup

`mix mimir_analytics.setup` installs the `json` and `core_functions`
DuckDB extensions into the local extension directory (network, once per
machine/CI runner). Tests themselves never touch the network.

## MotherDuck notes

The connection string is the seam: `{:motherduck, db}` attaches
`md:` using the `MOTHERDUCK_TOKEN` environment variable and everything else (DDL, mappers, views) is
identical SQL. **Hard rule:** never `ATTACH` with an empty token — the
extension silently falls back to interactive browser auth and hangs the NIF
(`MimirAnalytics.Store` guards this). Tests never touch the network; the
single `:live`-tagged test (excluded by default) exercises the real attach.

