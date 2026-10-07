defmodule MimirOrchestration.AgentRunner.RMA do
  @moduledoc """
  Default agent adapter backed by `req_managed_agents`, an optional dependency.
  It needs `{:req_managed_agents, ">= 0.10.0 and < 0.11.0"}` in your dependencies,
  or pass another `MimirOrchestration.AgentRunner` as `:agent_runner`. Without it,
  `run/3` returns `{:error, {:missing_dependency, :req_managed_agents}}`.

  References are `{provider, {:spec, spec}}` or `{provider, {:handle, handle}}`.
  Specs are provisioned through `ReqManagedAgents.provision/2` with its default
  options; supplied handles skip provisioning. The generic provisioning cache is
  sufficient for this adapter's in-process reuse; hosts needing lifecycle
  management own that policy.

  Model configuration, turn guard and correlation metadata pass to
  `ReqManagedAgents.Session.run/2`. Keyword-list and map handles are merged into
  session options; other handles use `:handle`. The result projects text,
  terminal, usage and the provider's stop reason into a `NodeResult`, whose
  `raw` field retains the complete result. Atom terminals and stop reasons
  become strings; other stop reasons pass through.
  """
  @behaviour MimirOrchestration.AgentRunner

  alias MimirOrchestration.NodeResult

  @impl true
  @spec run(term(), term(), keyword()) :: {:ok, NodeResult.t()} | {:error, term()}
  def run({provider, ref}, input, opts) do
    provision_fun = Keyword.get(opts, :provision_fun, &default_provision/2)
    session_fun = Keyword.get(opts, :session_fun, &default_session/3)

    with {:ok, handle} <- ensure_handle(provider, ref, provision_fun),
         {:ok, result} <- session_fun.(provider, handle, session_opts(input, opts)) do
      {:ok, project(result)}
    end
  end

  defp ensure_handle(provider, {:spec, _} = spec, provision_fun),
    do: provision_fun.(provider, spec)

  defp ensure_handle(_provider, {:handle, _} = handle, _), do: {:ok, handle}

  defp session_opts(input, opts) do
    [prompt: input]
    |> maybe_put(:model_config, opts[:model])
    |> maybe_put(:turn_guard, opts[:turn_guard])
    |> maybe_put(:telemetry_metadata, opts[:metadata])
    |> maybe_put(:handler, opts[:handler])
    |> maybe_put(:timeout, opts[:timeout])
  end

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
    defp default_provision(_provider, _spec),
      do: {:error, {:missing_dependency, :req_managed_agents}}

    defp default_session(_provider, _handle, _opts),
      do: {:error, {:missing_dependency, :req_managed_agents}}
  end
end
