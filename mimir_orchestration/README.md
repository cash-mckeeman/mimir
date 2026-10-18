# mimir_orchestration

Compile and execute workflows of agent, tool and model steps. The compiler
checks dependency order, references, registered targets and declared budgets.
The host supplies agent references, tool callables and a router.

Routed steps carry `opts[:binding]`; adapters bind their target before applying
execution controls. Unrouted steps retain their explicitly supplied options.
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
  hosts can provide another implementation through `:agent_runner`. Through
  `Exec.run/3`, `:agent_runner_opts` are plain data, so a session `:handler` is a
  module.
- The router is a `Mimir.RouterClient` implementation, passed as
  `router: {module, opts}`. Each routed step sends it a flat request: the step
  descriptor's fields at the top level, as `Mimir.Descriptor.parse/1` reads them,
  plus `workflow_id`, `step_id`, `parent_step_id`, `fanout_hint` and `path`. A
  `Mimir.RouteResponse` placement with a grant produces the step's Binding. Any other `{:ok, _}` or `{:error, _}` fails the step
  with `{:routing_failed, reason}`; a router that raises, exits, throws or returns
  anything else fails it with `{:step_crashed, step_id, reason}`.
  `Mimir.RouterClient.HTTP` is the HTTP transport.
- `MimirOrchestration.Executor` runs the lowered steps. `Runner.run/2` and
  `Exec.run/3` take `executor: module`; the default,
  `MimirOrchestration.Executor.InMemory`, runs them in this node. What reaches an
  executor is plain data: a function, pid, reference or port in the steps or in
  any option `Runner.run/2` reads but `:executor` returns
  `{:error, {:not_serialisable, path, kind}}` and no step runs.
  Callables are MFAs, `{module, function, extra_args}`. Plain data is not a
  credential policy: an executor that persists payloads must not store router
  credentials, such as a `Mimir.RouterClient.HTTP` bearer token, raw.
- Tool registry entries are MFAs, `{module, function, extra_args}`, invoked as
  `apply(module, function, [input | extra_args])`.
  Raised tool exceptions become `{:error, {:tool_crashed, exception}}`.
- `llm` steps use the optional `req_llm` dependency, or `llm_opts: [chat: mfa]`,
  invoked with `%{model: model, prompt: prompt}` first. Without either, the step
  fails with `{:missing_dependency, :req_llm}`.
- With the optional `jido` dependency, `MimirOrchestration.AgentTool` wraps an
  agent reference as a `Jido.Action`. Its context can override the configured
  runtime and supply correlation metadata.

```elixir
{:ok, reference} =
  MimirOrchestration.AgentRunner.RMA.Reference.new(
    provider: ReqManagedAgents.Providers.Local,
    runtime: "local",
    resource: {:handle, local_handle}
  )

agent_registry = %{"assistant" => reference}
```

Pass gateway URLs explicitly as `data_plane: %{chat_completions: gateway_base}` or with the managed-agents API wire. A routed Binding is constructed during dispatch and carries the grant credential; do not persist it. Custom AgentRunner implementations keep their own reference types.

## Dependencies

`mimir_workflows` supplies the workflow IR, compiler passes, graph operations and
templates. `mimir` supplies the router behaviour, typed routing responses and grant guards.
The optional `req_managed_agents` supplies the default agent adapter; without it,
pass `:agent_runner`. `jido` and `req_llm` are optional integrations; `jason` and
`telemetry` support serialization and events.
