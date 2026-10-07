defmodule Mimir.Event.OTel do
  @moduledoc """
  Renders a `Mimir.Event` as OpenTelemetry attributes. This is the one place
  Mimir's events meet the OpenTelemetry GenAI vocabulary.

  `render/1` returns `%{type: String.t(), attributes: %{optional(String.t()) =>
  term()}}`. `type` is the domain string (`"llm"`, `"agent"` or `"workflow"`).

  ## Conventions

  Attribute names follow the OpenTelemetry GenAI semantic conventions as read at
  [`open-telemetry/semantic-conventions-genai@4f85037`](https://github.com/open-telemetry/semantic-conventions-genai/tree/4f85037ef86e92c510d2ef881a58f1076f6fc0e4):
  `docs/gen-ai/gen-ai-agent-spans.md`, and the `gen_ai.operation.name`
  registry in `model/gen-ai/registry.yaml`. The conventions have Development
  status. At that commit, `gen_ai.operation.name` takes:

    * inference: `chat`, `generate_content`, `text_completion`, `embeddings`,
      `retrieval`, `fetch_response`
    * agents: `create_agent`, `invoke_agent`, `plan`, `execute_tool`
    * workflows: `invoke_workflow`, with the workflow named by
      `gen_ai.workflow.name`
    * memory: `search_memory`, `create_memory`, `update_memory`,
      `upsert_memory`, `delete_memory`, `create_memory_store`,
      `delete_memory_store`

  `render/1` itself sets only `invoke_agent`.

  ## `llm`

  `:usage` with a `usage` map, `:tool_call` with a `tool` map, and `:reasoning`
  render exactly what the retired `Mimir.TurnEvents.GenAI` builders produced:
  `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens`; `gen_ai.tool.name`
  and `gen_ai.tool.call.id`, with the call-id key present even when the id is
  `nil`; and a bare `milestone` key, with no `gen_ai.` prefix, defaulting to `""`.
  `test/support/fixtures/gen_ai_compat/` holds those shapes as captured from
  the old builders.

  Every other `llm` event, `:tool_result` included and `:usage` or `:tool_call`
  without its map, exports `raw` with its keys stringified.

  ## `agent`

  Every agent event renders `gen_ai.operation.name` as `invoke_agent`, and
  `session_id`, when set, as `gen_ai.conversation.id`. `:session_open` and
  `:session_reattach` both invoke an agent that exists or is brokered for the
  session; `create_agent` describes creating an agent in a remote agent
  service, which neither event records.

  `:turn_start`, `:turn_end`, `:terminal` and `:error` are moments within one
  invocation and have no operation name of their own. They add
  `mimir.agent.event`, holding the event type.

  ## `workflow`

  Workflow events render `mimir.workflow.event` (the event type) and, when set,
  `mimir.workflow.id` and `mimir.workflow.step_id`. They carry no `gen_ai.*`
  attribute. That is a choice, not a gap in the conventions, which define
  `invoke_workflow` and `gen_ai.workflow.name`: workflow events stay on
  `mimir.workflow.*` until an ingest consumes them, so that the emitter changes
  alongside a consumer it can be tested against.

  ## `mimir.path`

  An event with a non-empty `path` adds `mimir.path` to any domain's
  attributes: its frames joined with `/`, for example
  `"workflow:wf_123/workflow_step:step_5/agent:sess_9"`. An event with an empty
  `path` renders without it.
  """

  alias Mimir.Event

  @agent_subtype_types [:turn_start, :turn_end, :terminal, :error]

  @spec render(Event.t()) :: %{type: String.t(), attributes: %{optional(String.t()) => term()}}
  def render(%Event{domain: :llm} = ev),
    do: %{type: "llm", attributes: llm_attributes(ev) |> put_path(ev.path)}

  def render(%Event{domain: :agent} = ev),
    do: %{type: "agent", attributes: agent_attributes(ev) |> put_path(ev.path)}

  def render(%Event{domain: :workflow} = ev),
    do: %{type: "workflow", attributes: workflow_attributes(ev) |> put_path(ev.path)}

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

  defp put_path(attrs, []), do: attrs
  defp put_path(attrs, path), do: Map.put(attrs, "mimir.path", Enum.join(path, "/"))

  defp stringify_keys(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
