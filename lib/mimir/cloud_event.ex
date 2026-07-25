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

  # The CloudEvents v1.0 attributes this struct models by name. Anything else at
  # the top level of a wire event is an extension attribute.
  @known_attributes ~w(specversion id source type time subject datacontenttype
                       dataschema data data_base64)

  @enforce_keys [:id, :source, :type]
  defstruct [
    :id,
    :source,
    :type,
    :time,
    :subject,
    :dataschema,
    :data_base64,
    specversion: @specversion,
    datacontenttype: @datacontenttype,
    data: %{},
    extensions: %{}
  ]

  @typedoc """
  `data` is the opaque body — any JSON value, carried verbatim and never
  interpreted here (the documented open-payload carve-out). `data_base64` holds a
  base64-encoded binary body instead; at most one of the two is ever set.

  `extensions` is the open bag of CloudEvents extension attributes (the other
  documented carve-out): string-keyed, carried verbatim in both directions, never
  interpreted. It is how context this release does not model by name —
  `traceparent`/`tracestate` for distributed tracing, `partitionkey`, a
  broker-specific attribute — survives a parse/render trip intact.
  """
  @type t :: %__MODULE__{
          specversion: String.t(),
          id: String.t(),
          source: String.t(),
          type: String.t(),
          time: String.t() | nil,
          subject: String.t() | nil,
          datacontenttype: String.t(),
          dataschema: String.t() | nil,
          data: term(),
          data_base64: String.t() | nil,
          extensions: %{optional(String.t()) => term()}
        }

  @doc """
  Build a CloudEvent from `attrs`. `:id`, `:source`, `:type` are required
  non-empty strings; `:time` (when present) must be RFC3339; `:subject`,
  `:data`, and `:data_base64` are optional. `:data` may be any JSON value and is
  stored verbatim; supplying both `:data` and `:data_base64` is an error, since
  the JSON event format allows only one body. `:dataschema` (when present) must be
  a non-empty string, and `:extensions` a string-keyed map whose keys do not
  shadow a CloudEvents attribute this struct already models.

  `:datacontenttype` defaults to `"application/json"` but is honored when given —
  a producer labelling a non-JSON body gets the label it asked for. `:specversion`
  may be supplied only as `"1.0"`; any other value is rejected rather than
  silently replaced with the constant. Returns
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
         dataschema = Map.get(a, :dataschema),
         :ok <- validate_optional_string(dataschema, :dataschema),
         data_base64 = Map.get(a, :data_base64),
         :ok <- validate_optional_string(data_base64, :data_base64),
         :ok <- validate_one_body(a),
         extensions = Map.get(a, :extensions, %{}),
         :ok <- validate_extensions(extensions),
         :ok <- check_specversion(Map.get(a, :specversion, @specversion)) do
      {:ok,
       %__MODULE__{
         id: id,
         source: source,
         type: type,
         time: time,
         subject: subject,
         dataschema: dataschema,
         datacontenttype: string_or_default(Map.get(a, :datacontenttype), @datacontenttype),
         data: Map.get(a, :data, %{}),
         data_base64: data_base64,
         extensions: extensions
       }}
    end
  end

  @doc """
  Wrap a lifecycle `Mimir.Event` as a CloudEvent. Sets `type` from the event's
  domain/type via `Mimir.CloudEvent.Types.for_event/1` and `data` from
  `Mimir.Event.to_wire/1`; the producer supplies `:id`, `:source` (required) and
  optionally `:time`, `:subject`, `:dataschema`, `:extensions` — this function
  invents none of them. Same validation and return contract as `new/1`.
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
      dataschema: Map.get(o, :dataschema),
      extensions: Map.get(o, :extensions, %{}),
      data: Mimir.Event.to_wire(event)
    })
  end

  @doc """
  Render to the CloudEvents JSON event format: a string-keyed map with the
  context attributes and the body as top-level keys. `time`/`subject`/`dataschema`
  are omitted when nil; the body is rendered as `data_base64` when one is set and
  as `data` otherwise, never both. Extension attributes are merged back in at the
  top level, where CloudEvents puts them. Always succeeds.
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
    |> put_present("dataschema", ce.dataschema)
    |> Map.merge(ce.extensions)
  end

  @doc """
  Parse a CloudEvents JSON event-format map. Fallible and tolerant: `specversion`,
  `id`, `source`, `type` must be present non-empty strings (else
  `{:error, {:bad_cloudevent, {:missing, key}}}`), and `specversion` must be
  `"1.0"` (else `{:error, {:bad_cloudevent, {:unsupported_specversion, v}}}`).
  `time`/`subject`/`dataschema` are tolerant (absent or non-string → nil); the body
  is carried verbatim — `data` is any JSON value, `data_base64` any string. Every
  unrecognized top-level string key is preserved as an extension attribute rather
  than discarded, so context this release does not model by name survives a
  parse/render trip. Never raises.
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
         dataschema: tolerant_string(wire["dataschema"]),
         data: Map.get(wire, "data", %{}),
         data_base64: tolerant_string(wire["data_base64"]),
         extensions: collect_extensions(wire)
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

  # An extension must not shadow an attribute the struct already models — to_wire/1
  # merges extensions last, so a shadowing key would silently clobber the real one.
  defp validate_extensions(ext) when is_map(ext) do
    Enum.reduce_while(ext, :ok, fn {k, _v}, :ok ->
      cond do
        not is_binary(k) or k == "" -> {:halt, {:error, {:bad_cloudevent, {:bad_extension, k}}}}
        k in @known_attributes -> {:halt, {:error, {:bad_cloudevent, {:reserved_extension, k}}}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp validate_extensions(ext), do: {:error, {:bad_cloudevent, {:bad_extensions, ext}}}

  # Tolerant inverse: whatever is left at the top level once the modeled
  # attributes are removed. Non-string keys can't occur in decoded JSON, but a
  # caller may hand us a hand-built map, so they're dropped rather than trusted.
  defp collect_extensions(wire) do
    wire
    |> Map.drop(@known_attributes)
    |> Map.filter(fn {k, _v} -> is_binary(k) and k != "" end)
  end

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
