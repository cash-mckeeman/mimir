defmodule MimirWorkflows do
  @moduledoc """
  Deterministic workflow engine for agent steps on the BEAM.

  Hosts supply step implementations and compiler passes. The library
  provides compilation and local execution without persistence, model
  calls or bundled policy. Its only runtime dependency is `:telemetry`.

  ## Module map

    * `MimirWorkflows.Step` — the behaviour: `run(params, upstream)`.
    * `MimirWorkflows.Graph` — pure edge-list math (adjacency,
      reachability, strict-upstream, cycle detection).
    * `MimirWorkflows.Dag` — Kahn minimal-phase `waves/1` + opt-in
      `infer_edges/1` (`input_from` ∪ prev-in-order).
    * `MimirWorkflows.Spec` / `MimirWorkflows.Diagnostic` — the
      string-keyed IR and its structured findings.
    * `MimirWorkflows.Compiler` (+ `MimirWorkflows.Compiler.Pass`) —
      built-in schema/dag/refs passes; host passes append; diagnostics
      accumulate across all passes.
    * `MimirWorkflows.Template` — `{{step_id}}` / `{{params.x}}`
      extraction and resolution.
    * `MimirWorkflows.Runner` — phased parallel execution with telemetry.
    * `MimirWorkflows.Result` — the usage-fold convention.

  ## End to end

  Declare a workflow as data, compile it, run it, account for it:

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

      {:ok, spec, _warnings} =
        MimirWorkflows.Compiler.compile(spec_map, passes: [{MyApp.PolicyPass, tenant}])

      # The host lowers IR steps onto Step modules of its choosing —
      # "kind" vocabulary belongs to the host, not the library.
      steps =
        for step <- spec.steps do
          %{id: step.id, module: MyApp.kind_module(step.kind),
            params: step.raw, depends_on: step.depends_on}
        end

      {:ok, results} =
        MimirWorkflows.Runner.run(steps, telemetry_meta: %{workflow_id: "wf_1"})

      MimirWorkflows.Result.usage(results)
      #=> %{"input_tokens" => 1200, "output_tokens" => 340, "calls" => 2}

  Steps resolve their own dataflow at execution time via
  `MimirWorkflows.Template.resolve/2` with the upstream results the
  runner hands them.
  """
end
