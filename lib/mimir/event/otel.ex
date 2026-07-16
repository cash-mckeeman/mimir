defmodule Mimir.Event.OTel do
  @moduledoc """
  Canonical export-edge rendering for `Mimir.Event` — one mapper, one private
  renderer per domain, no per-consumer drift (spec §3.3: "`gen_ai` is a wire
  format at the export edge, not a domain model").

  `render/1` returns `%{type: String.t(), attributes: %{optional(String.t()) =>
  term()}}`. `type` is the domain string (`"llm"`, `"agent"`, `"workflow"`);
  `attributes` is the OTel-attribute-shaped map for that event.

  ## `llm` domain — byte-compatible with the retired `Mimir.TurnEvents.GenAI`

  The `llm` mapper reproduces today's exported attribute names exactly for the
  three shapes the old `Mimir.TurnEvents.GenAI` helpers built:
  `gen_ai.usage.input_tokens`/`gen_ai.usage.output_tokens`,
  `gen_ai.tool.name`/`gen_ai.tool.call.id` (including the case where the tool
  id is `nil` — the call-id key is still present with a `nil` value, matching
  `GenAI.tool_use/1`'s behavior verbatim), and the bare `"milestone"` reasoning
  marker (note: no `gen_ai.` prefix on `milestone` historically — preserved as
  documented, not "fixed"). Proof lives in
  `test/support/fixtures/gen_ai_compat/*.json`, captured from the *live*
  `Mimir.TurnEvents.GenAI` helpers before this module existed (see the fixture
  freeze commit and `test/mimir/event/otel_test.exs`, which assert
  `render/1`'s output byte-equal against those frozen fixtures.

  `llm` types with no dedicated historical builder (`request_start`,
  `request_stop`, `turn_complete`, `exception`) had no fixed attribute shape
  before this vocabulary existed — the old `Mimir.Ingest.classify/1` forwarded
  whatever provider-shaped map arrived verbatim as the event's `gen_ai`
  payload. This mapper preserves that posture: it renders the event's `raw`
  map (string-keying any atom keys), so a collector that stashes
  provider-native `gen_ai.*` attributes in `raw` gets them exported unchanged.

  ## `agent` domain — OTel GenAI *agent* conventions

  `gen_ai.operation.name` is `"invoke_agent"` for every agent event — verified
  against the OpenTelemetry Semantic Conventions for Generative AI Agents
  (`gen-ai-agent-spans`, semconv-genai ~v1.40/1.41, still `Development` status
  as of 2026-07: https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/).
  The registry defines two agent operation names, `create_agent` and
  `invoke_agent`; Mimir's session lifecycle (`:session_open`/
  `:session_reattach`) is semantically an invocation of an existing or
  freshly-brokered agent in both cases, not the OTel `create_agent` sense
  (typically remote agent-service *creation*, e.g. an Assistants-API
  `POST /assistants`), so both map to `invoke_agent`.

  `session_id`, when present, renders as `gen_ai.conversation.id` — the
  semconv-registered attribute for correlating a stream of events into one
  conversation/session (open-telemetry/semantic-conventions-genai#51).

  `:turn_start`/`:turn_end`/`:terminal`/`:error` have no OTel operation name of
  their own (they're sub-moments within one `invoke_agent`), so the mapper
  adds a `mimir.agent.event` sub-type attribute carrying the Mimir type
  string, keeping that distinction legible at the export edge.
  `:session_open`/`:session_reattach` do not get this extra attribute — the
  operation name plus the correlation id already identify the invocation.

  ## `workflow` domain — plain `mimir.workflow.*`, no GenAI pretense

  Workflow spans do not participate in the GenAI vocabulary at all: `render/1`
  never emits a `gen_ai.*` key for a `:workflow` event. Attributes are
  `mimir.workflow.id`, `mimir.workflow.step_id` (both omitted when `nil`, same
  idiom as `Event.to_wire/1`'s `put_present`), and `mimir.workflow.event`
  (the Mimir type string, always present).
  """

  alias Mimir.Event

  @agent_subtype_types [:turn_start, :turn_end, :terminal, :error]

  @spec render(Event.t()) :: %{type: String.t(), attributes: %{optional(String.t()) => term()}}
  def render(%Event{domain: :llm} = ev), do: %{type: "llm", attributes: llm_attributes(ev)}

  def render(%Event{domain: :agent} = ev),
    do: %{type: "agent", attributes: agent_attributes(ev)}

  def render(%Event{domain: :workflow} = ev),
    do: %{type: "workflow", attributes: workflow_attributes(ev)}

  # -- llm -------------------------------------------------------------

  defp llm_attributes(%Event{
         type: :usage,
         usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
       }) do
    %{
      "gen_ai.usage.input_tokens" => input_tokens,
      "gen_ai.usage.output_tokens" => output_tokens
    }
  end

  defp llm_attributes(%Event{type: :tool_call, tool: %{id: id, name: name}}) do
    %{
      "gen_ai.tool.name" => name,
      "gen_ai.tool.call.id" => id
    }
  end

  defp llm_attributes(%Event{type: :reasoning, raw: raw}) do
    %{"milestone" => milestone(raw)}
  end

  defp llm_attributes(%Event{raw: raw}), do: stringify_keys(raw)

  defp milestone(raw), do: to_string(Map.get(raw, "milestone") || Map.get(raw, :milestone) || "")

  # -- agent -------------------------------------------------------------

  defp agent_attributes(%Event{type: type, session_id: session_id}) do
    %{"gen_ai.operation.name" => "invoke_agent"}
    |> put_present("gen_ai.conversation.id", session_id)
    |> maybe_put_agent_subtype(type)
  end

  defp maybe_put_agent_subtype(attrs, type) when type in @agent_subtype_types,
    do: Map.put(attrs, "mimir.agent.event", Atom.to_string(type))

  defp maybe_put_agent_subtype(attrs, _type), do: attrs

  # -- workflow -------------------------------------------------------------

  defp workflow_attributes(%Event{type: type, workflow_id: workflow_id, step_id: step_id}) do
    %{"mimir.workflow.event" => Atom.to_string(type)}
    |> put_present("mimir.workflow.id", workflow_id)
    |> put_present("mimir.workflow.step_id", step_id)
  end

  # -- shared -------------------------------------------------------------

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
