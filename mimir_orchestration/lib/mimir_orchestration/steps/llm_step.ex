defmodule MimirOrchestration.Steps.LlmStep do
  @moduledoc """
  Runs one model call with the routed `:model` configuration.

  `:chat` is an MFA, `{module, function, extra_args}`, invoked as
  `apply(module, function, [%{model: model, prompt: prompt} | extra_args])`. It
  returns `{:ok, text}`, `{:ok, response}` or `{:error, reason}`; errors pass
  through. The default uses the optional `req_llm` dependency; without it, the
  default returns `{:error, {:missing_dependency, :req_llm}}`.
  """

  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(prompt, opts) when is_binary(prompt) do
    {module, function, extra_args} = Keyword.get(opts, :chat, {__MODULE__, :req_llm_chat, []})
    model = Keyword.fetch!(opts, :model)

    case apply(module, function, [%{model: model, prompt: prompt} | extra_args]) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:ok, resp} -> {:ok, extract_text(resp)}
      {:error, reason} -> {:error, reason}
    end
  end

  if Code.ensure_loaded?(ReqLLM) do
    @doc false
    def req_llm_chat(%{model: model, prompt: prompt}), do: ReqLLM.generate_text(model, prompt, [])
    defp extract_text(resp), do: ReqLLM.Response.text(resp)
  else
    @doc false
    def req_llm_chat(_call), do: {:error, {:missing_dependency, :req_llm}}
    defp extract_text(resp), do: inspect(resp)
  end
end
