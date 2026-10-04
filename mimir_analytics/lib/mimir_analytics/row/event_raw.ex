defmodule MimirAnalytics.Row.EventRaw do
  @moduledoc """
  One row of `events_raw` — a single raw event from either a Capture session
  result or a gateway request log's `turn_events`, tagged by `source` so
  downstream consumers can tell which shape `payload` carries, and by `domain`
  (`llm | agent | workflow`) when the source event carries the typed vocabulary.

  `ce_id`/`ce_source`/`ce_type` are the CloudEvents v1.0 envelope attributes,
  populated only for gateway rows whose source entry was enveloped; they are
  NULL for session/eval rows and for pre-envelope gateway history. `ts` is the
  envelope's wall-clock `time` (UTC RFC3339) — NULL wherever no producer ever
  emitted one. The source event's monotonic `ts` is never stored here; it
  rides verbatim inside `payload`.
  """

  @enforce_keys [:scope_id, :seq, :source_file]
  defstruct [
    :scope_id,
    :seq,
    :ts,
    :type,
    :domain,
    :ce_id,
    :ce_source,
    :ce_type,
    :payload,
    :source,
    :source_file
  ]

  @type source :: String.t()

  @type t :: %__MODULE__{
          # run_id or mimir_request_id
          scope_id: String.t() | nil,
          seq: integer(),
          ts: String.t() | nil,
          type: String.t() | nil,
          domain: String.t() | nil,
          ce_id: String.t() | nil,
          ce_source: String.t() | nil,
          ce_type: String.t() | nil,
          payload: map(),
          # session | gateway | eval
          source: source(),
          source_file: String.t()
        }

  @doc """
  Build a `t()` from the mapper-resolved context. `:domain` and the three
  `:ce_*` envelope attributes are optional and default to `nil`.
  """
  @spec new(%{
          required(:scope_id) => String.t() | nil,
          required(:seq) => integer(),
          required(:ts) => String.t() | nil,
          optional(:domain) => String.t() | nil,
          optional(:ce_id) => String.t() | nil,
          optional(:ce_source) => String.t() | nil,
          optional(:ce_type) => String.t() | nil,
          required(:type) => String.t() | nil,
          required(:payload) => map(),
          required(:source) => source(),
          required(:source_file) => String.t()
        }) :: t()
  def new(
        %{
          scope_id: scope_id,
          seq: seq,
          ts: ts,
          type: type,
          payload: payload,
          source: source,
          source_file: file
        } = attrs
      ) do
    %__MODULE__{
      scope_id: scope_id,
      seq: seq,
      ts: ts,
      type: type,
      domain: Map.get(attrs, :domain),
      ce_id: Map.get(attrs, :ce_id),
      ce_source: Map.get(attrs, :ce_source),
      ce_type: Map.get(attrs, :ce_type),
      payload: payload,
      source: source,
      source_file: file
    }
  end
end
