defmodule MimirOrchestration.Exec do
  @moduledoc """
  Executes a compiled workflow with required parameters.

  Agent steps use the configured `AgentRunner`; tools execute without routing;
  model steps use `LlmStep`. Templates resolve against the results of the step's
  dependencies, with agent text projected for model prompts. Missing parameters
  and unresolved references return tagged errors. Results are the steps' values.

  Options: `:router`, `:workflow_id`, `:max_concurrency`, `:step_timeout` and
  `:executor` pass to `MimirOrchestration.Runner.run/2`; `:agent_runner` (default
  `MimirOrchestration.AgentRunner.RMA`), `:agent_runner_opts` and `:llm_opts`
  configure dispatch. All but `:executor` cross the executor seam, so they must be
  plain data: a function, pid, reference or port in them returns
  `{:error, {:not_serialisable, path, kind}}` before any step runs.
  """
  alias MimirOrchestration.{AgentRunner, Compiled, Runner, StepCall, StepInput}
  alias MimirOrchestration.Steps.{LlmStep, ToolStep}

  @spec run(Compiled.t(), map(), keyword()) :: Runner.result()
  def run(%Compiled{} = compiled, params, opts) do
    with :ok <- check_params(compiled, params) do
      # Exec's dispatch configuration, carried in the :run MFA's extra_args.
      config = %{
        agent_runner: Keyword.get(opts, :agent_runner, AgentRunner.RMA),
        agent_runner_opts: Keyword.get(opts, :agent_runner_opts, []),
        llm_opts: Keyword.get(opts, :llm_opts, [])
      }

      runner_opts =
        opts
        |> Keyword.take([:router, :workflow_id, :max_concurrency, :step_timeout, :executor])
        |> Keyword.merge(run: {__MODULE__, :dispatch, [config]}, params: params)

      compiled.steps |> Enum.map(&lower_step/1) |> Runner.run(runner_opts)
    end
  end

  @doc false
  # The :run MFA every lowered plan dispatches through.
  @spec dispatch(StepCall.t(), map()) :: {:ok, term()} | {:error, term()}
  def dispatch(%StepCall{target: {:agent, ref, runtime}, input: input, opts: opts}, config) do
    opts = opts |> Keyword.merge(config.agent_runner_opts) |> maybe_put(:runtime, runtime)
    config.agent_runner.run(ref, input, opts)
  end

  def dispatch(%StepCall{target: {:tool, callable}, input: input, opts: opts}, _config),
    do: ToolStep.run(callable, input, opts)

  def dispatch(%StepCall{target: :llm, input: prompt, opts: opts}, config),
    do: LlmStep.run(prompt, Keyword.merge(opts, config.llm_opts))

  defp check_params(compiled, params) do
    case Enum.reject(compiled.params, &Map.has_key?(params, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_params, missing}}
    end
  end

  # Compiler.compile/2's refs pass rejects dangling refs, but Exec.run/3 accepts any
  # %Compiled{}; an unresolved ref fails its step at dispatch.
  defp lower_step(step) do
    base = %{
      id: step.id,
      input: %StepInput{template: step.input_template, textify: step.kind == "llm"},
      descriptor: step.descriptor,
      depends_on: step.depends_on
    }

    case step.kind do
      "agent" -> Map.put(base, :target, {:agent, step.target, step.runtime})
      "tool" -> base |> Map.put(:target, {:tool, step.target}) |> Map.put(:route, false)
      "llm" -> Map.put(base, :target, :llm)
    end
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)
end
