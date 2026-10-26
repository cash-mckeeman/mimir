-- Analytical projections over the run-record tables.

CREATE OR REPLACE VIEW v_eval_trend AS
SELECT date_trunc('day', ts) AS day, agent, runtime, mode,
       count(*)                                   AS cases,
       avg(CASE WHEN passed THEN 1.0 ELSE 0.0 END) AS pass_rate
FROM eval_outcomes
GROUP BY 1, 2, 3, 4;

-- Cost per passing case:
-- numerator = cost of ALL attempts of cases that eventually passed. Failed
-- cases' spend excluded, retries of passing cases included.
CREATE OR REPLACE VIEW v_parity_cost AS
WITH case_status AS (
  SELECT r.runtime, e.agent, e.suite, e.case_id,
         bool_or(e.passed)                        AS ever_passed,
         count(*)                                 AS attempts,
         -- sums of BIGINT are HUGEINT in DuckDB (a {hi, lo} tuple through the
         -- NIF), so cast back to BIGINT at every aggregation
         CASE WHEN count(r.cost_microdollars) = count(*)
              THEN CAST(sum(r.cost_microdollars) AS BIGINT)
         END                                     AS case_cost
  FROM eval_outcomes e
  JOIN runs r ON r.run_id = e.run_id
  GROUP BY 1, 2, 3, 4
), runtime_cost AS (
  SELECT runtime,
         count(*) FILTER (WHERE ever_passed) AS passing_cases,
         CASE WHEN count(case_cost) FILTER (WHERE ever_passed)
                        = count(*) FILTER (WHERE ever_passed)
              THEN CAST(sum(case_cost) FILTER (WHERE ever_passed) AS BIGINT)
         END AS total_cost_microdollars
  FROM case_status
  GROUP BY runtime
)
SELECT runtime, passing_cases, total_cost_microdollars,
       CASE WHEN passing_cases > 0
            THEN total_cost_microdollars / passing_cases
       END AS microdollars_per_passing_case
FROM runtime_cost;

CREATE OR REPLACE VIEW v_tool_signatures AS
SELECT run_id,
       string_agg(name, '->' ORDER BY seq)        AS signature,
       count(*)                                   AS n_tools
FROM tool_calls
GROUP BY run_id;

CREATE OR REPLACE VIEW v_flow_tree AS
SELECT r.workflow_id, r.step_id, r.parent_step_id, r.run_id,
       r.agent_name, r.runtime, r.terminal, r.turns,
       r.cost_microdollars, r.started_at, r.finished_at
FROM runs r
WHERE r.workflow_id IS NOT NULL
ORDER BY r.workflow_id, r.started_at;

CREATE OR REPLACE VIEW v_memory_evidence AS
SELECT mp.entry_id, mp.event, mp."at", mp.evidence_ref,
       r.run_id, r.agent_name, r.terminal
FROM memory_provenance mp
LEFT JOIN runs r ON r.run_id = mp.run_id;
