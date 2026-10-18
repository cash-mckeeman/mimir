defmodule MimirOrchestration.Steps.LlmStep do
  @moduledoc """
  Runs one model call using a routed Binding or an explicit unrouted model.

  The routed target is runtime `"local"` with per-run model selection. A
  chat-completions data plane uses the configured base URL, the routed catalog
  model and the grant as bearer credential. Without a data plane, the direct
  model carries no grant credential.

  `:chat` remains an injectable MFA for the call. The default requires `req_llm`;
  without it, returns `{:error, {:missing_dependency, :req_llm}}`.
  """

  alias Mimir.Binding
  alias Mimir.Binding.Target

  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(prompt, opts) when is_binary(prompt) do
    {module, function, extra_args} = Keyword.get(opts, :chat, {__MODULE__, :req_llm_chat, []})

    with {:ok, model, call_opts} <- model_call(opts) do
      case apply(module, function, [%{model: model, prompt: prompt, opts: call_opts} | extra_args]) do
        {:ok, text} when is_binary(text) -> {:ok, text}
        {:ok, resp} -> {:ok, extract_text(resp)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp model_call(opts) do
    case opts[:binding] do
      nil -> {:ok, Keyword.fetch!(opts, :model), []}
      %Binding{} = binding -> routed_call(binding)
    end
  end

  defp routed_call(binding) do
    with {:ok, target} <-
           Target.new(runtime: "local", runtime_model: true, data_plane: :chat_completions),
         {:ok, binding} <- Binding.bind(binding, target) do
      config = Binding.model_config(binding)

      case config do
        %{base_url: base, api_key: key, model: model} ->
          {:ok,
           %{
             provider: :openai,
             id: model,
             base_url: base,
             extra: %{wire: %{protocol: "openai_chat"}}
           }, [api_key: key]}

        %{model: model} ->
          {:ok, model, []}
      end
    end
  end

  if Code.ensure_loaded?(ReqLLM) do
    @doc false
    def req_llm_chat(%{model: model, prompt: prompt, opts: opts}),
      do: ReqLLM.generate_text(model, prompt, opts)

    defp extract_text(resp), do: ReqLLM.Response.text(resp)
  else
    @doc false
    def req_llm_chat(_call), do: {:error, {:missing_dependency, :req_llm}}
    defp extract_text(resp), do: inspect(resp)
  end
end
