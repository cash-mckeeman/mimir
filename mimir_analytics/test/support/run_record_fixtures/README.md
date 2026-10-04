# Run-record fixtures

Fixtures exercise the session, gateway and evaluation wire shapes. Tests
assert the rows produced by ingestion. Identifiers and response text are
synthetic; captured shapes retain field names, value types and nesting.

- `eval_report.json` is synthetic and includes a matched judge result and
  a case without a judge result.
- `session_local.jsonl` and `session_legacy_run_id_fallback.jsonl` are
  hand-built session examples. The latter exercises the legacy metadata
  run-id fallback. Neither represents a producer emitting event entries.
- `session_duplicate_run_id.jsonl` is synthetic: duplicate session ids
  force a primary-key failure and test rollback of both rows and the ledger.
- `session_seam_crosscheck.jsonl` derives from captured session-writer
  output. Agent and case identifiers and response text have been replaced;
  terminal values, stop-reason shapes, usage and correlation fields remain.
  It tests session identity precedence and the absence of event entries.
- `gateway_export.jsonl` combines captured CloudEvents with synthetic
  request and historical bare-event lines. Envelope entries were captured
  from separate gateway requests and spliced into one array, so subjects
  need not match the enclosing request. Tenant, agent and source values
  have been replaced. The fixture covers both envelope and legacy reads.
- `run_record.jsonl`, `run_record_rma_terminal.jsonl` and
  `run_record_error.jsonl` derive from a run-record writer executed against
  constructed run results, with synthetic agent names. They exercise the
  flat shape and tool-call roll-ups. The first used an off-contract stop
  reason and no session result: its null terminal fields do not certify
  valid session termination. The second supplies a session with `end_turn`;
  the third has no session and records a timeout classification.

Inline synthetic event maps in `session_test.exs` test optional event
mapping. They are not evidence that a session producer emits those events.
