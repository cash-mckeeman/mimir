defmodule MimirOrchestration.Exec do
  @moduledoc """
  Executes a compiled workflow with required parameters.

  Agent steps use the configured `AgentRunner`; tools execute without routing;
  model steps use `LlmStep`. Templates resolve against completed results, with
  agent text projected for model prompts. Missing parameters and unresolved
  references return tagged errors. Successful results are unwrapped.
  """
  alias MimirOrchestration.{AgentRunner, Compiled, NodeResult, Runner}
  alias MimirOrchestration.Steps.{LlmStep, ToolStep}
  alias MimirWorkflows.Template

  @spec run(Compiled.t(), map(), keyword()) ::
          {:ok, %{results: map(), workflow_id: String.t()}} | {:error, term()}
  def run(%Compiled{} = compiled, params, opts) do
    with :ok <- check_params(compiled, params) do
      agent_runner = Keyword.get(opts, :agent_runner, AgentRunner.RMA)
      agent_runner_opts = Keyword.get(opts, :agent_runner_opts, [])
      llm_opts = Keyword.get(opts, :llm_opts, [])

      runner_opts =
        opts
        |> Keyword.take([:router, :workflow_id, :max_concurrency])
        |> Keyword.put(:run_fun, dispatch_fun(agent_runner, agent_runner_opts, llm_opts))

      compiled.steps
      |> Enum.map(&lower_step(&1, params))
      |> Runner.run(runner_opts)
      |> unwrap_results()
    end
  end

  defp check_params(compiled, params) do
    case Enum.reject(compiled.params, &Map.has_key?(params, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_params, missing}}
    end
  end

  defp lower_step(step, params) do
    input_fun = fn results ->
      # Compiler.compile's refs pass guarantees resolvability for plans it
      # produced — but Exec.run accepts any %Compiled{}, so a foreign/stale
      # compiler (or hand-built plan) can still hand us a dangling ref. That
      # must surface as the runner's uniform {:error, _} shape, never a
      # crashed Task.async_stream task (Runner.dispatch/3 short-circuits on
      # this tagged error before invoking run_fun).
      # llm prompts consume text by definition: an agent step's %NodeResult{}
      # (or a tool's "text"-keyed map) contributes its text when interpolated
      # into a prompt (the engine Template has no nested-ref paths, and
      # embedded refs interpolate via to_string/1).
      ctx_results =
        case step.kind do
          "llm" -> results |> unwrap_map() |> textify()
          _ -> unwrap_map(results)
        end

      case Template.resolve(step.input_template, %{results: ctx_results, params: params}) do
        {:ok, resolved} -> resolved
        {:error, {:unresolved_ref, ref}} -> {:error, {:unresolved_ref, ref}}
      end
    end

    base = %{
      id: step.id,
      input: input_fun,
      descriptor: step.descriptor,
      depends_on: step.depends_on
    }

    case step.kind do
      "agent" -> Map.put(base, :target, {:agent, step.target, step.runtime})
      "tool" -> base |> Map.put(:target, {:tool, step.target}) |> Map.put(:route, false)
      "llm" -> Map.put(base, :target, :llm)
    end
  end

  defp dispatch_fun(agent_runner, agent_runner_opts, llm_opts) do
    fn
      {:agent, ref, runtime}, input, run_opts ->
        agent_runner.run(
          ref,
          input,
          run_opts |> Keyword.merge(agent_runner_opts) |> maybe_put(:runtime, runtime)
        )

      {:tool, callable}, input, run_opts ->
        ToolStep.run(callable, input, run_opts)

      :llm, prompt, run_opts ->
        LlmStep.run(prompt, Keyword.merge(run_opts, llm_opts))
    end
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  defp unwrap_map(results) do
    Map.new(results, fn
      {id, {:ok, v}} -> {id, v}
      {id, other} -> {id, other}
    end)
  end

  defp textify(results) do
    Map.new(results, fn
      {id, %NodeResult{text: text}} when is_binary(text) -> {id, text}
      {id, %{"text" => text}} when is_binary(text) -> {id, text}
      pair -> pair
    end)
  end

  defp unwrap_results({:ok, %{results: results} = out}),
    do: {:ok, %{out | results: unwrap_map(results)}}

  defp unwrap_results(other), do: other
end
