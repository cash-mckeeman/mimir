defmodule MimirOrchestration.StepInput do
  @moduledoc """
  A step input that is resolved when the step is dispatched: a `{{ref}}` template
  (`MimirWorkflows.Template`) over the step's dependencies' results and the run's
  params. With `textify: true` (llm steps), a dependency's `%NodeResult{text: t}` or
  `%{"text" => t}` contributes `t`.
  """
  alias MimirOrchestration.NodeResult
  alias MimirWorkflows.Template

  @enforce_keys [:template]
  defstruct [:template, textify: false]

  @type t :: %__MODULE__{template: term(), textify: boolean()}

  @doc "Resolves `input` against `results` (the step's dependencies') and `params`."
  @spec resolve(t(), map(), map()) :: {:ok, term()} | {:error, {:unresolved_ref, term()}}
  def resolve(%__MODULE__{template: template, textify: textify}, results, params) do
    results = if textify, do: textify(results), else: results
    Template.resolve(template, %{results: results, params: params})
  end

  defp textify(results) do
    Map.new(results, fn
      {id, %NodeResult{text: text}} when is_binary(text) -> {id, text}
      {id, %{"text" => text}} when is_binary(text) -> {id, text}
      pair -> pair
    end)
  end
end
