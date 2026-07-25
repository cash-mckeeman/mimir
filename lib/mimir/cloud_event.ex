defmodule Mimir.CloudEvent do
  @moduledoc """
  A CloudEvents v1.0 envelope — the ecosystem's uniform event wrapper. It carries
  any domain body (a `Mimir.Event` wire map, a routing-decision record, ...) in
  `data`, with the CloudEvents core context attributes as siblings.

  Body-agnostic: this layer never decodes `data` into a typed struct. A consumer
  that wants the body calls the body's own parser on `data`, keyed by `type`.

  `Mimir.Event` is unchanged by this module — it becomes the `data` of a
  CloudEvent, not a CloudEvent itself (see `from_event/2`). The `id`/`source`/
  `time` a CloudEvent needs but `Mimir.Event` lacks are supplied by the *producer*
  that wraps it (the gateway stamps a wall-clock `time`, a `source` URI, a
  natural-key `id`); this module invents none of them, it validates their shape.

  Construction (`new/1`, `from_event/2`) is strict; `from_wire/1` is tolerant —
  the same posture as `Mimir.Event`: we only ever write well-formed events, and a
  reader never rejects an otherwise-valid event over an optional-field hint.
  """

  @specversion "1.0"
  @datacontenttype "application/json"

  @enforce_keys [:id, :source, :type]
  defstruct [
    :id,
    :source,
    :type,
    :time,
    :subject,
    specversion: @specversion,
    datacontenttype: @datacontenttype,
    data: %{}
  ]

  @type t :: %__MODULE__{
          specversion: String.t(),
          id: String.t(),
          source: String.t(),
          type: String.t(),
          time: String.t() | nil,
          subject: String.t() | nil,
          datacontenttype: String.t(),
          data: map()
        }

  @doc """
  Build a CloudEvent from `attrs`. `:id`, `:source`, `:type` are required
  non-empty strings; `:time` (when present) must be RFC3339; `:subject`/`:data`
  are optional. Returns `{:ok, t()} | {:error, {:bad_cloudevent, reason}}`.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, {:bad_cloudevent, term()}}
  def new(attrs) do
    a = Map.new(attrs)

    with {:ok, id} <- required(a, :id),
         {:ok, source} <- required(a, :source),
         {:ok, type} <- required(a, :type),
         time = Map.get(a, :time),
         :ok <- validate_time(time),
         subject = Map.get(a, :subject),
         :ok <- validate_optional_string(subject, :subject) do
      {:ok,
       %__MODULE__{
         id: id,
         source: source,
         type: type,
         time: time,
         subject: subject,
         data: Map.get(a, :data, %{})
       }}
    end
  end

  @doc """
  RFC3339 shape check: a non-empty string `DateTime.from_iso8601/1` accepts
  (RFC3339 is the ISO-8601 profile it parses, and it requires a UTC offset).
  """
  @spec valid_time?(term()) :: boolean()
  def valid_time?(t) when is_binary(t), do: match?({:ok, _, _}, DateTime.from_iso8601(t))
  def valid_time?(_), do: false

  # Shared by new/1 (atom keys) and from_wire/1 (string keys) — Map.get matches
  # whichever key type the caller's map uses.
  defp required(map, key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:bad_cloudevent, {:missing, key}}}
    end
  end

  defp validate_time(nil), do: :ok

  defp validate_time(t) do
    if valid_time?(t), do: :ok, else: {:error, {:bad_cloudevent, {:bad_time, t}}}
  end

  # CloudEvents: an OPTIONAL attribute, if present, MUST be a non-empty string.
  defp validate_optional_string(nil, _key), do: :ok
  defp validate_optional_string(v, _key) when is_binary(v) and v != "", do: :ok
  defp validate_optional_string(_v, key), do: {:error, {:bad_cloudevent, {:blank, key}}}
end
