defmodule MimirOrchestration.Eval do
  @moduledoc """
  Scores a workflow plan without executing it.

  Returns compile error and warning counts. For a successful compile, also
  lists unconsumed steps other than the final declared step.
  """
  alias MimirOrchestration.{Compiler, Policy}

  @ref_rx ~r/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/

  @spec plan_score(map(), Policy.t()) :: %{
          compiles: boolean(),
          warnings: non_neg_integer(),
          errors: non_neg_integer(),
          dead_steps: [String.t()]
        }
  def plan_score(spec, %Policy{} = policy) do
    case Compiler.compile(spec, policy) do
      {:ok, compiled} ->
        %{
          compiles: true,
          errors: 0,
          warnings: length(compiled.warnings),
          dead_steps: dead_steps(spec)
        }

      {:error, diags} ->
        {errors, warnings} = Enum.split_with(diags, &(&1.severity == :error))
        %{compiles: false, errors: length(errors), warnings: length(warnings), dead_steps: []}
    end
  end

  defp dead_steps(spec) do
    steps = spec |> Map.get("steps", []) |> List.wrap() |> Enum.filter(&is_map/1)
    ids = steps |> Enum.map(& &1["id"]) |> MapSet.new()

    consumed =
      steps
      |> Enum.flat_map(fn s -> refs(s["input"] || s["prompt"]) ++ List.wrap(s["depends_on"]) end)
      |> MapSet.new()

    terminal = steps |> List.last() |> then(&(&1 && &1["id"]))

    ids |> MapSet.difference(consumed) |> MapSet.delete(terminal) |> Enum.sort()
  end

  defp refs(term) when is_binary(term),
    do: @ref_rx |> Regex.scan(term, capture: :all_but_first) |> List.flatten()

  defp refs(term) when is_map(term), do: term |> Map.values() |> Enum.flat_map(&refs/1)
  defp refs(term) when is_list(term), do: Enum.flat_map(term, &refs/1)
  defp refs(_), do: []
end
