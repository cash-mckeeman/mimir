defmodule MimirWorkflows.Result do
  @moduledoc """
  Usage accounting over a run's results — the documented convention hosts
  follow so cost lands per-run without this library knowing about pricing.

  Steps that spend put a `"usage"` map in their result:

      %{"input_tokens" => 120, "output_tokens" => 40, "calls" => 1}

  Missing keys count as zero; results that are not maps, and maps without
  `"usage"`, contribute nothing.
  Hosts price the folded totals themselves (the pricing oracle is a host
  concern, never this library's).
  """

  @usage_keys ~w(input_tokens output_tokens calls)

  @doc """
  Folds `"usage"` maps across a `MimirWorkflows.Runner.run/2` results map.
  """
  @spec usage(%{term() => term()}) :: %{String.t() => non_neg_integer()}
  def usage(results) do
    zero = Map.new(@usage_keys, &{&1, 0})

    results
    |> Map.values()
    |> Enum.reduce(zero, fn
      %{} = result, acc ->
        usage = Map.get(result, "usage", %{})
        Map.new(acc, fn {key, total} -> {key, total + Map.get(usage, key, 0)} end)

      _not_a_map, acc ->
        acc
    end)
  end
end
