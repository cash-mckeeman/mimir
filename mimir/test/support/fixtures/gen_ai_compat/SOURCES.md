# `gen_ai_compat` fixtures

`*_attrs.json` are live goldens, asserted byte-equal against
`Mimir.Event.OTel.render/1`'s output in `test/mimir/event/otel_test.exs` —
do not delete.

`*_envelope.json` are **not** exercised by any test in this repo as of
mimir 0.4.0 (the old `%{"seq", "ts", "type", "gen_ai" => map()}` envelope
they capture was retired in the 0.4.0 big-bang rewrite — see
`CHANGELOG.md`). They are kept intentionally as legacy-envelope references
for `mimir_gateway`'s Part-2 `request_log.gen_ai_events` → `turn_events`
backfill transformer, which needs real-shaped old-envelope fixtures to test
against. Do not delete them here.
