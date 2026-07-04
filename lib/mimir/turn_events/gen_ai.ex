defmodule Mimir.TurnEvents.GenAI do
  @moduledoc """
  Dependency-free builders for binary-keyed `gen_ai.*` attribute maps
  (OpenTelemetry GenAI semantic conventions).

  Adapters that understand a specific client library's telemetry metadata
  live with the embedder, next to the telemetry handler that receives that
  library's events. This module carries only the shared vocabulary that
  needs no such library.
  """

  @doc "Milestone marker for reasoning progress events."
  @spec reasoning(map()) :: %{optional(String.t()) => String.t()}
  def reasoning(metadata), do: %{"milestone" => to_string(metadata[:milestone] || "")}

  @doc "Tool invocation attributes. Accepts atom- or string-keyed call maps."
  @spec tool_use(map()) :: %{optional(String.t()) => term()}
  def tool_use(call) do
    %{
      "gen_ai.tool.name" => call[:name] || call["name"],
      "gen_ai.tool.call.id" => call[:id] || call["id"]
    }
  end

  @doc "The OTel usage token pair."
  @spec usage(non_neg_integer(), non_neg_integer()) :: %{
          optional(String.t()) => non_neg_integer()
        }
  def usage(input_tokens, output_tokens) do
    %{
      "gen_ai.usage.input_tokens" => input_tokens,
      "gen_ai.usage.output_tokens" => output_tokens
    }
  end
end
