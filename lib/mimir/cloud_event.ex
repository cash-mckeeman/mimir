defmodule Mimir.CloudEvent do
  @moduledoc """
  A CloudEvents v1.0 envelope — the ecosystem's uniform event wrapper. It carries
  any domain body (a `Mimir.Event` wire map, a routing-decision record, ...) in
  `data`, with the CloudEvents core context attributes as siblings.

  Body-agnostic: this layer never decodes `data` into a typed struct. A consumer
  that wants the body calls the body's own parser on `data`, keyed by `type`.
  `data` is therefore **any JSON value**, not just an object — CloudEvents permits
  an array, string, number, or boolean body, and the envelope carries whatever it
  is verbatim rather than coercing it. A non-JSON (binary) body travels
  base64-encoded in `data_base64` instead, per the JSON event format; the two are
  mutually exclusive and decoding `data_base64` is the consumer's job.

  `Mimir.Event` is unchanged by this module — it becomes the `data` of a
  CloudEvent, not a CloudEvent itself (see `from_event/2`). The `id`/`source`/
  `time` a CloudEvent needs but `Mimir.Event` lacks are supplied by the *producer*
  that wraps it (the gateway stamps a wall-clock `time`, a `source` URI, a
  natural-key `id`); this module invents none of them, it validates their shape.

  Construction (`new/1`, `from_event/2`) is strict; `from_wire/1` is tolerant —
  the same posture as `Mimir.Event`: we only ever write well-formed events, and a
  reader never rejects an otherwise-valid event over an optional-field hint.
  """

  alias Mimir.CloudEvent.Types

  @specversion "1.0"
  @datacontenttype "application/json"

  @enforce_keys [:id, :source, :type]
  defstruct [
    :id,
    :source,
    :type,
    :time,
    :subject,
    :data_base64,
    specversion: @specversion,
    datacontenttype: @datacontenttype,
    data: %{}
  ]

  @typedoc """
  `data` is the opaque body — any JSON value, carried verbatim and never
  interpreted here (the documented open-payload carve-out). `data_base64` holds a
  base64-encoded binary body instead; at most one of the two is ever set.
  """
  @type t :: %__MODULE__{
          specversion: String.t(),
          id: String.t(),
          source: String.t(),
          type: String.t(),
          time: String.t() | nil,
          subject: String.t() | nil,
          datacontenttype: String.t(),
          data: term(),
          data_base64: String.t() | nil
        }

  @doc """
  Build a CloudEvent from `attrs`. `:id`, `:source`, `:type` are required
  non-empty strings; `:time` (when present) must be RFC3339; `:subject`,
  `:data`, and `:data_base64` are optional. `:data` may be any JSON value and is
  stored verbatim; supplying both `:data` and `:data_base64` is an error, since
  the JSON event format allows only one body. Returns
  `{:ok, t()} | {:error, {:bad_cloudevent, reason}}`.
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
         :ok <- validate_optional_string(subject, :subject),
         data_base64 = Map.get(a, :data_base64),
         :ok <- validate_optional_string(data_base64, :data_base64),
         :ok <- validate_one_body(a) do
      {:ok,
       %__MODULE__{
         id: id,
         source: source,
         type: type,
         time: time,
         subject: subject,
         data: Map.get(a, :data, %{}),
         data_base64: data_base64
       }}
    end
  end

  @doc """
  Wrap a lifecycle `Mimir.Event` as a CloudEvent. Sets `type` from the event's
  domain/type via `Mimir.CloudEvent.Types.for_event/1` and `data` from
  `Mimir.Event.to_wire/1`; the producer supplies `:id`, `:source` (required) and
  optionally `:time`, `:subject` — this function invents none of them. Same
  validation and return contract as `new/1`.
  """
  @spec from_event(Mimir.Event.t(), map() | keyword()) ::
          {:ok, t()} | {:error, {:bad_cloudevent, term()}}
  def from_event(%Mimir.Event{} = event, opts) do
    o = Map.new(opts)

    new(%{
      id: Map.get(o, :id),
      source: Map.get(o, :source),
      type: Types.for_event(event),
      time: Map.get(o, :time),
      subject: Map.get(o, :subject),
      data: Mimir.Event.to_wire(event)
    })
  end

  @doc """
  Render to the CloudEvents JSON event format: a string-keyed map with the
  context attributes and the body as top-level keys. `time`/`subject` are omitted
  when nil; the body is rendered as `data_base64` when one is set and as `data`
  otherwise, never both. Always succeeds.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = ce) do
    %{
      "specversion" => ce.specversion,
      "id" => ce.id,
      "source" => ce.source,
      "type" => ce.type,
      "datacontenttype" => ce.datacontenttype
    }
    |> put_body(ce)
    |> put_present("time", ce.time)
    |> put_present("subject", ce.subject)
  end

  @doc """
  Parse a CloudEvents JSON event-format map. Fallible and tolerant: `specversion`,
  `id`, `source`, `type` must be present non-empty strings (else
  `{:error, {:bad_cloudevent, {:missing, key}}}`), and `specversion` must be
  `"1.0"` (else `{:error, {:bad_cloudevent, {:unsupported_specversion, v}}}`).
  `time`/`subject` are tolerant (absent or non-string → nil); the body is carried
  verbatim — `data` is any JSON value, `data_base64` any string. Never raises.
  """
  @spec from_wire(term()) :: {:ok, t()} | {:error, {:bad_cloudevent, term()}}
  def from_wire(wire) when is_map(wire) do
    with {:ok, sv} <- required(wire, "specversion"),
         :ok <- check_specversion(sv),
         {:ok, id} <- required(wire, "id"),
         {:ok, source} <- required(wire, "source"),
         {:ok, type} <- required(wire, "type") do
      {:ok,
       %__MODULE__{
         specversion: sv,
         id: id,
         source: source,
         type: type,
         time: tolerant_string(wire["time"]),
         subject: tolerant_string(wire["subject"]),
         datacontenttype: string_or_default(wire["datacontenttype"], @datacontenttype),
         data: Map.get(wire, "data", %{}),
         data_base64: tolerant_string(wire["data_base64"])
       }}
    end
  end

  def from_wire(other), do: {:error, {:bad_cloudevent, {:invalid_wire, other}}}

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

  # The JSON event format carries the body in `data` XOR `data_base64`.
  defp validate_one_body(attrs) do
    if Map.has_key?(attrs, :data) and not is_nil(Map.get(attrs, :data_base64)) do
      {:error, {:bad_cloudevent, :ambiguous_body}}
    else
      :ok
    end
  end

  defp put_body(map, %__MODULE__{data_base64: b64}) when is_binary(b64),
    do: Map.put(map, "data_base64", b64)

  defp put_body(map, %__MODULE__{data: data}), do: Map.put(map, "data", data)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp check_specversion(@specversion), do: :ok
  defp check_specversion(v), do: {:error, {:bad_cloudevent, {:unsupported_specversion, v}}}

  defp tolerant_string(s) when is_binary(s) and s != "", do: s
  defp tolerant_string(_), do: nil

  defp string_or_default(s, _default) when is_binary(s) and s != "", do: s
  defp string_or_default(_, default), do: default
end
