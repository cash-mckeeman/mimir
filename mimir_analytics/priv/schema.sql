-- Run-record schema. Tables and columns evolve additively.

CREATE TABLE IF NOT EXISTS workflow_runs (
    workflow_id        TEXT PRIMARY KEY,
    tenant_id          TEXT,
    started_at         TIMESTAMP,
    finished_at        TIMESTAMP,
    status             TEXT,           -- completed | step_failed | unknown
    source_file        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS steps (
    workflow_id        TEXT,
    step_id            TEXT,
    parent_step_id     TEXT,
    agent_name         TEXT,
    status             TEXT,           -- ok | error | halted
    started_at         TIMESTAMP,
    finished_at        TIMESTAMP,
    source_file        TEXT NOT NULL,
    PRIMARY KEY (workflow_id, step_id)
);

CREATE TABLE IF NOT EXISTS runs (
    run_id             TEXT PRIMARY KEY,   -- session id or synthesized local id
    workflow_id        TEXT,
    step_id            TEXT,
    parent_step_id     TEXT,
    tenant_id          TEXT,
    agent_digest       TEXT,
    agent_name         TEXT,
    agent_version      TEXT,
    runtime            TEXT,               -- claude_managed | agentcore | local
    provider           TEXT,
    model              TEXT,
    lane               TEXT,
    outcome            TEXT,               -- ok | error (the producer's derived verdict)
    terminal           TEXT,               -- end_turn | terminated | ...
    stop_reason        TEXT,
    error_class        TEXT,               -- classification only, never the raw error term
    turns              INTEGER,
    input_tokens       BIGINT,
    output_tokens      BIGINT,
    cost_microdollars  BIGINT,             -- source-provided cost, missing values become zero
    started_at         TIMESTAMP,
    finished_at        TIMESTAMP,
    source_file        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS turns (
    run_id             TEXT,
    turn               INTEGER,            -- 1-based
    terminal           TEXT,
    input_tokens       BIGINT,
    output_tokens      BIGINT,
    source_file        TEXT NOT NULL,
    PRIMARY KEY (run_id, turn)
);

CREATE TABLE IF NOT EXISTS tool_calls (
    run_id             TEXT,
    turn               INTEGER,
    seq                INTEGER,            -- order within the run
    tool_use_id        TEXT,
    name               TEXT,
    kind               TEXT,               -- custom | server | rollup
    input              JSON,
    source_file        TEXT NOT NULL,
    PRIMARY KEY (run_id, seq)
);

CREATE TABLE IF NOT EXISTS model_calls (
    mimir_request_id   TEXT PRIMARY KEY,
    run_id             TEXT,               -- nullable, resolved via workflow/step
    workflow_id        TEXT,
    step_id            TEXT,
    parent_step_id     TEXT,
    virtual_key_id     TEXT,
    parent_key_id      TEXT,
    tenant_id          TEXT,
    lane               TEXT,
    provider           TEXT,
    model_id           TEXT,
    status             TEXT,               -- success | error
    finish_reason      TEXT,
    input_tokens       BIGINT,
    output_tokens      BIGINT,
    cost_microdollars  BIGINT,
    latency_ms         INTEGER,
    fallback           BOOLEAN,
    error_class        TEXT,
    ts                 TIMESTAMP,
    source_file        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS routing_decisions (
    decision_id        TEXT PRIMARY KEY,   -- "rd_..."
    workflow_id        TEXT,
    step_id            TEXT,
    grant_id           TEXT,
    task_class         TEXT,
    budget_ceiling_microdollars BIGINT,
    latency_tolerance_ms INTEGER,
    runtime_preference TEXT,
    agent_digest       TEXT,
    outcome            TEXT,               -- placement | no_candidate
    chosen_model       TEXT,
    chosen_lane        TEXT,
    reasons            JSON,
    candidates         JSON,
    snapshot_at        TIMESTAMP,
    degraded_lanes     JSON,
    ts                 TIMESTAMP,
    source_file        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS eval_outcomes (
    ts                 TIMESTAMP,
    agent              TEXT,               -- widened vs the original eval-ingest format
    suite              TEXT,               -- widened
    runtime            TEXT,               -- widened
    run_id             TEXT,               -- widened, nullable
    mode               TEXT,
    threshold          DOUBLE,
    pass_rate          DOUBLE,
    case_id            TEXT,
    passed             BOOLEAN,
    reason             TEXT,
    elapsed_ms         INTEGER,
    judge_passed       BOOLEAN,
    judge_reasoning    TEXT,
    judge_elapsed_ms   INTEGER,
    source_file        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events_raw (
    scope_id           TEXT,               -- run_id or mimir_request_id
    seq                BIGINT,
    ts                 TIMESTAMP,          -- CloudEvents `time` (UTC), NULL pre-envelope
    type               TEXT,
    domain             TEXT,               -- llm | agent | workflow (nullable)
    ce_id              TEXT,               -- CloudEvents `id`     (nullable)
    ce_source          TEXT,               -- CloudEvents `source` (nullable)
    ce_type            TEXT,               -- CloudEvents `type`   (nullable)
    payload            JSON,
    source             TEXT,               -- session | gateway | eval
    source_file        TEXT NOT NULL
);

-- Memory provenance rows are supplied by consumers.
CREATE TABLE IF NOT EXISTS memory_provenance (
    entry_id           TEXT,
    event              TEXT,               -- proposed|recalled|accepted|corrected|promoted|demoted|archived
    agent              TEXT,
    run_id             TEXT,
    evidence_ref       TEXT,
    "at"               TIMESTAMP,
    source_file        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS ingest_rejections (
    digest             TEXT PRIMARY KEY,   -- hex sha256 of the rejected file's bytes
    source_file        TEXT NOT NULL,
    source             TEXT NOT NULL,
    reason             TEXT NOT NULL,
    rejected_at        TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS ingest_ledger (
    digest             TEXT PRIMARY KEY,   -- hex sha256 of the file's bytes
    source_file        TEXT NOT NULL,      -- basename, for provenance
    source             TEXT NOT NULL,
    ingested_at        TIMESTAMP NOT NULL,
    rows               INTEGER NOT NULL
);
