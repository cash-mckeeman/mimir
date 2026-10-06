# mimir_orchestration

Compile and execute workflows of agent, tool and model steps. The compiler
checks dependency order, references, registered targets and declared budgets.
The host supplies agent references, tool callables and a router.

A routed step dispatches only on a placement with a grant: the runner forwards
the grant's model configuration and a grant-derived turn guard to the step.
Agent runners own guard enforcement; model-call transports own
their runtime budget enforcement, and `LlmStep` does not apply a local turn guard.
Workflow and step identifiers accompany routing, agent metadata and telemetry.
Tool steps execute locally without routing.

## Usage

```elixir
alias MimirOrchestration.{Compiler, Exec, Policy}

spec = %{
  "name" => "answer",
  "version" => 1,
  "params" => ["question"],
  "steps" => [
    %{
      "id" => "research",
      "kind" => "agent",
      "agent" => "researcher",
      "input" => "{{params.question}}",
      "descriptor" => %{
        "task_class" => "analysis",
        "budget_ceiling_microdollars" => 300_000
      },
      "depends_on" => []
    }
  ]
}

# Registry values are opaque references interpreted by the host's AgentRunner.
policy = %Policy{
  agent_registry: %{"researcher" => MyApp.Registry.agent_ref("researcher")},
  budget_ceiling_microdollars: 1_000_000
}

{:ok, compiled} = Compiler.compile(spec, policy)
{:ok, %{results: results, workflow_id: workflow_id}} =
  Exec.run(compiled, %{"question" => "Explain the supplied document."},
    router: {MyApp.Router, []},
    agent_runner: MyApp.AgentRunner
  )
```

`Compiler.compile/2` returns `{:error, diagnostics}` for an invalid plan.
`Exec.run/3` returns each step's result value, or a tagged error when a step
fails. The rest of a failing step's wave finishes; later waves do not run. A
step that crashes or outlives `:step_timeout` returns
`{:error, {:step_crashed, step_id, reason}}` rather than exiting the caller.

`MimirOrchestration.Eval.plan_score/2` reports compile diagnostics and
unconsumed, nonterminal steps without executing the workflow.

## Host seams

- `MimirOrchestration.AgentRunner` runs an opaque agent reference and returns
  a `MimirOrchestration.NodeResult`. The default adapter uses `req_managed_agents`;
  hosts can provide another implementation through `:agent_runner`.
- The router is a `Mimir.RouterClient` implementation, passed as
  `router: {module, opts}`. Each routed step sends it a flat request: the step
  descriptor's fields at the top level, as `Mimir.Descriptor.parse/1` reads them,
  plus `workflow_id`, `step_id`, `parent_step_id`, `fanout_hint` and `path`. A
  `Mimir.RouteResponse` placement with a grant produces the step's model map and
  a `Mimir.Guard` turn guard. Any other `{:ok, _}` or `{:error, _}` fails the step
  with `{:routing_failed, reason}`; a router that raises, exits, throws or returns
  anything else fails it with `{:step_crashed, step_id, reason}`.
  `Mimir.RouterClient.HTTP` is the HTTP transport.
- Tool registry entries are one-argument functions or `{module, function}` pairs.
  Raised tool exceptions become `{:error, {:tool_crashed, exception}}`.
- `llm` steps use the optional `req_llm` dependency or an injected `:chat_fun`.
- With the optional `jido` dependency, `MimirOrchestration.AgentTool` wraps an
  agent reference as a `Jido.Action`. Its context can override the configured
  runtime and supply correlation metadata.

## Dependencies

`mimir_workflows` supplies the workflow IR, compiler passes, graph operations and
templates. `mimir` supplies the router behaviour, typed routing responses and grant guards.
`req_managed_agents` supplies the default agent adapter. `jido` and `req_llm`
are optional integrations; `jason` and `telemetry` support serialization and events.
