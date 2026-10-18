defmodule MimirOrchestration.AgentRunner.RMA do
  @moduledoc """
  Default agent adapter backed by the optional `req_managed_agents` dependency.

  Accepts an `MimirOrchestration.AgentRunner.RMA.Reference`. A routed call checks
  the target and native model before provisioning, then applies the Binding's
  model configuration, guard and correlation to the Session. Conflicting handle
  controls are refused.

  Without the dependency, returns `{:error, {:missing_dependency, :req_managed_agents}}`.
  """
  @behaviour MimirOrchestration.AgentRunner

  alias Mimir.Binding.Target
  alias MimirOrchestration.AgentRunner.RMA.Reference
  alias MimirOrchestration.NodeResult

  @impl true
  @spec run(Reference.t(), term(), keyword()) :: {:ok, NodeResult.t()} | {:error, term()}
  def run(%Reference{} = reference, input, opts) do
    provision_fun = Keyword.get(opts, :provision_fun, &default_provision/2)
    session_fun = Keyword.get(opts, :session_fun, &default_session/3)

    with {:ok, reference} <- Reference.new(reference),
         {:ok, session_opts} <- session_opts(reference, input, opts),
         {:ok, handle} <-
           ensure_handle(reference.provider, reference.resource, provision_fun),
         :ok <- check_handle(handle, session_opts),
         {:ok, result} <- session_fun.(reference.provider, handle, session_opts) do
      {:ok, project(result)}
    end
  end

  def run(_reference, _input, _opts), do: {:error, {:invalid_agent_reference, :reference}}

  defp ensure_handle(provider, {:spec, _} = spec, provision_fun),
    do: provision_fun.(provider, spec)

  defp ensure_handle(_provider, {:handle, _} = handle, _), do: {:ok, handle}

  defp session_opts(reference, input, opts) do
    base =
      [prompt: input]
      |> maybe_put(:model_config, opts[:model_config])
      |> maybe_put(:turn_guard, opts[:turn_guard])
      |> maybe_put(:telemetry_metadata, opts[:metadata])
      |> maybe_put(:handler, opts[:handler])
      |> maybe_put(:timeout, opts[:timeout])
      |> maybe_put(:max_turns, opts[:max_turns])

    case opts[:binding] do
      nil -> {:ok, base}
      %Mimir.Binding{} = binding -> apply_binding(reference, binding, base)
    end
  end

  defp check_handle({:handle, handle}, opts) when is_map(handle),
    do: check_handle({:handle, Map.to_list(handle)}, opts)

  defp check_handle({:handle, handle}, opts) when is_list(handle) do
    if Keyword.keyword?(handle) do
      case Enum.find([:notify | Keyword.keys(opts)], &Keyword.has_key?(handle, &1)) do
        nil -> :ok
        key -> {:error, {:handle_overrides_run_option, key}}
      end
    else
      :ok
    end
  end

  defp check_handle(_handle, _opts), do: :ok

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  defp project(result) do
    %NodeResult{
      text: Map.get(result, :text),
      terminal: result |> Map.get(:terminal) |> atom_to_string(),
      stop_reason: result |> Map.get(:stop_reason) |> raw_reason(),
      usage: result |> Map.get(:usage) |> usage_map(),
      raw: result
    }
  end

  defp atom_to_string(nil), do: nil
  defp atom_to_string(a) when is_atom(a), do: Atom.to_string(a)
  defp atom_to_string(other), do: other

  # stop_reason is the provider's raw native value — JSON-encodable maps and
  # strings pass through verbatim; atoms (Local) become strings.
  defp raw_reason(a) when is_atom(a) and not is_nil(a), do: Atom.to_string(a)
  defp raw_reason(other), do: other

  defp usage_map(nil), do: %{}

  defp usage_map(%{input_tokens: i, output_tokens: o}),
    do: %{"input_tokens" => i, "output_tokens" => o}

  defp usage_map(_), do: %{}

  if Code.ensure_loaded?(ReqManagedAgents) do
    alias ReqManagedAgents.Provider

    defp apply_binding(reference, binding, opts) do
      provider = reference.provider

      with {:ok, target} <-
             Target.new(
               runtime: reference.runtime,
               configured_model: reference.configured_model,
               runtime_model: Provider.supports?(provider, :runtime_model),
               data_plane: Provider.data_plane(provider)
             ),
           {:ok, binding} <- Mimir.Binding.bind(binding, target),
           {:ok, _native} <-
             Provider.native_model(provider, binding.placement.model) do
        metadata = Map.merge(opts[:telemetry_metadata] || %{}, Mimir.Binding.correlation(binding))

        {:ok,
         opts
         |> Keyword.put(:model_config, Mimir.Binding.model_config(binding))
         |> Keyword.put(:turn_guard, Mimir.Binding.guard(binding))
         |> Keyword.put(:telemetry_metadata, metadata)}
      end
    end

    defp default_provision(provider, {:spec, spec}) do
      case ReqManagedAgents.provision(provider, spec) do
        {:ok, handle} -> {:ok, {:handle, handle}}
        other -> other
      end
    end

    defp default_session(provider, {:handle, handle}, opts),
      do: ReqManagedAgents.Session.run(provider, splat_handle(handle, opts))

    defp splat_handle(handle, opts) when is_list(handle) do
      if Keyword.keyword?(handle), do: Keyword.merge(opts, handle), else: [handle: handle] ++ opts
    end

    defp splat_handle(handle, opts) when is_map(handle),
      do: Keyword.merge(opts, Map.to_list(handle))

    defp splat_handle(handle, opts), do: Keyword.put(opts, :handle, handle)
  else
    defp apply_binding(_reference, _binding, _opts),
      do: {:error, {:missing_dependency, :req_managed_agents}}

    defp default_provision(_provider, _spec),
      do: {:error, {:missing_dependency, :req_managed_agents}}

    defp default_session(_provider, _handle, _opts),
      do: {:error, {:missing_dependency, :req_managed_agents}}
  end
end
