defmodule MimirOrchestration.Steps.ToolStep do
  @moduledoc """
  Executes a tool callable locally. A callable is an MFA,
  `{module, function, extra_args}`, invoked as `apply(module, function, [input | extra_args])`;
  anything else returns `{:error, {:not_a_callable, other}}`.

  Tagged success and error tuples pass through; other return values become
  `{:ok, value}`. Raised exceptions return `{:error, {:tool_crashed, exception}}`.
  Tool steps skip routing and do not receive router grants.
  """

  @spec run(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(callable, input, _opts) do
    invoke(callable, input)
  rescue
    e -> {:error, {:tool_crashed, e}}
  end

  defp invoke({m, f, args}, input) when is_atom(m) and is_atom(f) and is_list(args),
    do: normalize(apply(m, f, [input | args]))

  defp invoke(other, _input), do: {:error, {:not_a_callable, other}}

  defp normalize({:ok, _} = ok), do: ok
  defp normalize({:error, _} = err), do: err
  defp normalize(other), do: {:ok, other}
end
