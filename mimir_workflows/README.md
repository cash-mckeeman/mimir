# mimir_workflows

**Deterministic workflows for agent steps on the BEAM.**

`mimir_workflows` provides a `Step` behaviour, DAG operations, a declarative
string-keyed workflow IR with pluggable compile passes, and an in-memory
phase runner with concurrency caps and explicit failure results.

Kind-agnostic by design — the IR validates universal shape; `"kind"`
vocabulary belongs to the host. One engine serves a code-review pipeline and
an agent composition equally.

## 30 seconds

```elixir
spec_map = %{
  "name" => "brief",
  "version" => 1,
  "params" => ["month"],
  "steps" => [
    %{"id" => "analyze", "kind" => "agent", "depends_on" => [],
      "input" => %{"q" => "KPIs for {{params.month}}"}},
    %{"id" => "narrate", "kind" => "agent",
      "depends_on" => ["analyze"], "input" => "{{analyze}}"}
  ]
}

# Compile: schema/dag/refs built-ins + your own passes (policy, budget, kinds).
# Diagnostics accumulate across ALL passes — the caller sees every problem at once.
{:ok, spec, _warnings} = MimirWorkflows.Compiler.compile(spec_map, passes: [{MyApp.PolicyPass, tenant}])

# Lower IR steps onto your Step modules and run: minimal phases, parallel in-phase.
steps =
  for step <- spec.steps do
    %{id: step.id, module: MyApp.kind_module(step.kind),
      params: step.raw, depends_on: step.depends_on}
  end

{:ok, results} = MimirWorkflows.Runner.run(steps, telemetry_meta: %{workflow_id: "wf_1"})

MimirWorkflows.Result.usage(results)
#=> %{"input_tokens" => 1200, "output_tokens" => 340, "calls" => 2}
```

## Invariants

- **Depends on nothing in-house** — no `Mimir.*`, no `ManagedAgents.*`, no
  RMA or Jido types (grep-enforced in CI). Only `:telemetry`.
- **Step ids are opaque terms, never atomized** — untrusted IR never mints
  atoms; parsed specs keep string ids.
- Policy, budget, allowlists, routing, agent registries are **host
  concerns**, delivered through `MimirWorkflows.Compiler.Pass` and step
  params/modules. Governed agent execution lives one layer up, in
  `mimir_orchestration`.
- **Graceful degradation** (convention): conditional steps stay in the DAG
  and no-op (`{:ok, %{"skipped" => true}}`) rather than mutating graph shape
  — the DAG stays static and analyzable.

## Telemetry

| event | measurements | metadata |
|---|---|---|
| `[:mimir_workflows, :run, :start]` | `system_time` | `run_ref` ∪ `telemetry_meta` |
| `[:mimir_workflows, :run, :stop]` | `duration` | `run_ref`, `status` |
| `[:mimir_workflows, :step, :start]` | `system_time` | `run_ref`, `step_id`, `phase` |
| `[:mimir_workflows, :step, :stop]` | `duration` | `run_ref`, `step_id`, `phase` |
| `[:mimir_workflows, :step, :exception]` | `duration` | + `reason` |

The `telemetry_meta` option is how hosts thread correlation ids into every
event without the library knowing what they mean.

## What this is not

No durability, persistence, resume, human-in-the-loop, or
compensation/rollback — a durable tier is a deliberate later decision, made
when a concrete workflow demands it, evaluated against existing OTP-native
options first. No conditionals in the IR (additive later). No workflow
registry (hosts persist their own declarations; the library compiles
values).

