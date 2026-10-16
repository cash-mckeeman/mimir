defmodule Mimir.Binding do
  @moduledoc """
  A route decision prepared for execution, with its correlation ids, placement,
  grant, and gateway URLs. Build it from `Mimir.RouteResponse` with `new/2`.

  Data-plane URLs are supplied per wire:

  - `:chat_completions` names an OpenAI-compatible chat-completions base. Traffic
    carries the routed model string verbatim and the grant key as bearer credential.
  - `:managed_agents_api` names a gateway proxy of the managed-agents API and
    replaces that API's base.

  The grant key is a gateway credential, not a provider credential. With no
  data-plane URLs, enforcement belongs to the control plane.

  A binding holds a bearer credential. Build it after any durable boundary and
  do not persist it. Inspect output omits the grant.
  """

  alias Mimir.Binding.Target
  alias Mimir.{Grant, Placement, RouteResponse}

  @derive {Inspect, except: [:grant]}
  @enforce_keys [:decision_id, :request_id, :placement, :grant]
  defstruct [
    :decision_id,
    :request_id,
    :workflow_id,
    :step_id,
    :placement,
    :grant,
    :target,
    data_plane_urls: %{}
  ]

  @typedoc "Gateway URL configuration, keyed by the closed data-plane wire vocabulary."
  @type data_plane_urls :: %{optional(Target.wire()) => String.t()}

  @type t :: %__MODULE__{
          decision_id: String.t(),
          request_id: String.t(),
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          placement: Placement.t(),
          grant: Grant.t(),
          data_plane_urls: data_plane_urls(),
          target: Target.t() | nil
        }

  @type invalid_reason ::
          {:verdict, :no_candidate}
          | :grant_missing
          | :decision_id_missing
          | {:correlation_conflict, :workflow_id | :step_id}
          | {:option, atom()}

  @typedoc "Correlation metadata shared by telemetry and execution consumers."
  @type correlation :: %{
          mimir_request_id: String.t(),
          decision_id: String.t(),
          workflow_id: String.t() | nil,
          step_id: String.t() | nil
        }

  @id_options [:request_id, :workflow_id, :step_id]

  @doc """
  Builds a binding from a placement verdict with a grant and non-empty decision id.

  Options are closed:

  - `:request_id` defaults to the decision id.
  - `:workflow_id` and `:step_id` fill gaps in the response. Different ids already
    present in the response return `{:correlation_conflict, key}`.
  - `:data_plane` maps data-plane wires to non-empty gateway URLs.

  Id options must be non-empty binaries or `nil` (unset). Absent or `nil`
  data-plane options become an empty map. No application environment is read.

  Returns `{:error, {:invalid_binding, reason}}` for a `:no_candidate` verdict,
  missing grant or decision id, conflicting correlation ids, or invalid options.
  Invalid options use `{:option, key}`, or `{:option, :not_a_keyword}` for a
  non-keyword container.
  """
  @spec new(RouteResponse.t(), keyword()) ::
          {:ok, t()} | {:error, {:invalid_binding, invalid_reason()}}
  def new(resp, opts \\ [])

  def new(%RouteResponse{verdict: :no_candidate}, _opts),
    do: {:error, {:invalid_binding, {:verdict, :no_candidate}}}

  def new(%RouteResponse{grant: nil}, _opts), do: {:error, {:invalid_binding, :grant_missing}}

  def new(%RouteResponse{decision_id: id}, _opts) when not is_binary(id) or id == "",
    do: {:error, {:invalid_binding, :decision_id_missing}}

  def new(
        %RouteResponse{
          verdict: :placement,
          placement: %Placement{} = placement,
          grant: %Grant{} = grant
        } =
          resp,
        opts
      ) do
    with :ok <- check_options(opts),
         {:ok, workflow_id} <- reconcile(:workflow_id, opts[:workflow_id], resp.workflow_id),
         {:ok, step_id} <- reconcile(:step_id, opts[:step_id], resp.step_id) do
      {:ok,
       %__MODULE__{
         decision_id: resp.decision_id,
         request_id: opts[:request_id] || resp.decision_id,
         workflow_id: workflow_id,
         step_id: step_id,
         placement: placement,
         grant: grant,
         data_plane_urls: opts[:data_plane] || %{}
       }}
    end
  end

  @doc "The binding's ids as telemetry and execution metadata."
  @spec correlation(t()) :: correlation()
  def correlation(%__MODULE__{} = binding) do
    %{
      mimir_request_id: binding.request_id,
      decision_id: binding.decision_id,
      workflow_id: binding.workflow_id,
      step_id: binding.step_id
    }
  end

  defp check_options(opts) do
    if is_list(opts) and Keyword.keyword?(opts),
      do: first_invalid_option(opts),
      else: {:error, {:invalid_binding, {:option, :not_a_keyword}}}
  end

  defp first_invalid_option(opts) do
    case Enum.find(opts, fn {key, value} -> not valid_option?(key, value) end) do
      nil -> :ok
      {key, _value} -> {:error, {:invalid_binding, {:option, key}}}
    end
  end

  defp valid_option?(key, value) when key in @id_options,
    do: is_nil(value) or non_empty_binary?(value)

  defp valid_option?(:data_plane, nil), do: true

  defp valid_option?(:data_plane, urls) when is_map(urls),
    do:
      Enum.all?(Map.to_list(urls), fn {wire, url} ->
        wire in Target.wires() and non_empty_binary?(url)
      end)

  defp valid_option?(_key, _value), do: false

  defp non_empty_binary?(value), do: is_binary(value) and value != ""

  defp reconcile(_key, nil, from_route), do: {:ok, from_route}
  defp reconcile(_key, given, nil), do: {:ok, given}
  defp reconcile(_key, same, same), do: {:ok, same}

  defp reconcile(key, _given, _from_route),
    do: {:error, {:invalid_binding, {:correlation_conflict, key}}}
end
