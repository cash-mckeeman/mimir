defmodule MimirOrchestration.Steps.ToolStep do
  @moduledoc """
  Executes a one-argument function or `{module, function}` callable locally.

  Tagged success and error tuples pass through; other return values become
  `{:ok, value}`. Raised exceptions return `{:error, {:tool_crashed, exception}}`.
  Tool steps skip routing and do not receive router grants.
  """

  @spec run(term(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(callable, input, _opts) do
    invoke(callable, input)
  rescue
    e -> {:error, {:tool_crashed, e}}
  end

  defp invoke(fun, input) when is_function(fun, 1), do: normalize(fun.(input))
  defp invoke({m, f}, input) when is_atom(m) and is_atom(f), do: normalize(apply(m, f, [input]))
  defp invoke(other, _input), do: {:error, {:not_a_callable, other}}

  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, _} = err), do: err
  defp normalize(other), do: {:ok, other}
end
