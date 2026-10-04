defmodule MimirOrchestration.Steps.LlmStep do
  @moduledoc """
  Runs one model call with the routed `:model` configuration.

  The default uses the optional `req_llm` dependency. Hosts may inject a
  `:chat_fun` accepting model, prompt and options. Returned errors pass through.
  """

  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(prompt, opts) when is_binary(prompt) do
    chat_fun = Keyword.get_lazy(opts, :chat_fun, &default_chat_fun/0)
    model = Keyword.fetch!(opts, :model)

    case chat_fun.(model, prompt, []) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:ok, resp} -> {:ok, extract_text(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  if Code.ensure_loaded?(ReqLLM) do
    defp default_chat_fun, do: fn model, prompt, _ -> ReqLLM.generate_text(model, prompt, []) end
    defp extract_text(resp), do: ReqLLM.Response.text(resp)
  else
    defp default_chat_fun do
      raise "kind: \"llm\" steps need a :chat_fun or the optional :req_llm dep — " <>
              "add {:req_llm, \"~> 1.10\"} to use the default"
    end

    defp extract_text(resp), do: inspect(resp)
  end
end
