defmodule Mimir.Event do
  @moduledoc """
  Domain-typed event envelope — the vocabulary root for everything that
  travels the `llm.* / agent.* / workflow.*` streams. `domain`/`type` are
  closed atom unions, `usage`/`tool` are the promoted commons consumers
  actually query, and anything provider-specific rides `raw` (the documented
  verbatim carve-out).

  Build with `llm/2`, `agent/2`, or `workflow/2` — each validates `type`
  against its domain's closed union and each `:path` frame against the
  closed frame-kind union (see "`path`" below), returning `{:ok, t()} |
  {:error, {:bad_type, domain, type} | {:bad_frame, frame}}`. Never
  construct the struct directly.

  `to_wire/1` / `from_wire/1` are the struct-in-BEAM / JSON-at-the-boundary
  pair (the house `DecisionRecord.to_event` pattern): `to_wire/1` always
  succeeds and produces a string-keyed map with nil ids omitted and nil
  `usage`/`tool` serialized as absent keys, never `null`. `from_wire/1` is the
  fallible, tolerant inverse — unknown top-level keys are ignored, an unknown
  `"type"` for the domain is `{:error, {:bad_event, {:bad_type, ...}}}`, and
  anything else unparseable is `{:error, {:bad_event, reason}}`. It never
  raises and never calls `String.to_atom/1` — types are resolved through
  fixed lookup maps built from the closed unions.

  Type unions are closed per release; tolerance for unknown telemetry frames
  lives at collection (collectors count + debug-log + drop), never here.

  ## `path` — materialized call-path provenance

  `path` is an ordered list of typed frames, **outermost → innermost
  spawner**: `["wf:wf_123", "step:step_5", "agent:sess_9"]` reads as "a
  workflow spawned a step which spawned an agent session." One event, in
  isolation, recreates its full spawn lineage and depth. An event's
  immediate spawner is `List.last(path)`; the empty list (the default)
  means "no recorded spawner" (a top-level event).

  Each frame is `"<kind>:<id>"` where `kind` is one of a **closed union per
  release** (`wf | step | agent | conv`) and `id` is a non-empty string.
  `conv` is reserved for a future conversation-scoped caller and is not
  produced by anything in this release. Requests are leaf events, not
  scopes — there is no `req:` frame; `request_id` stays a promoted id field
  on the event itself.

  `path` is the **spawn axis**: "who created me." It is deliberately
  distinct from a data-dependency axis some callers track separately
  ("whose output did I consume", e.g. a step's first upstream dependency) —
  a step can depend on another step's output without either having spawned
  the other. Do not conflate the two; this module only carries the spawn
  axis.

  Constructors validate every frame against the closed kind set and the
  non-empty-id rule, returning `{:error, {:bad_frame, frame}}` for the
  first offender (compile-time fixed kind list — never `String.to_atom/1`
  on caller-supplied data). `to_wire/1` includes the `"path"` key only when
  the list is non-empty (same omit-when-absent idiom as the id fields).
  `from_wire/1` treats `path` as malformed-optional data, the house
  `RouteResponse`-style posture for tolerant boundary parsing: a missing
  key is `[]`, and a non-list or any frame failing validation degrades the
  *whole* path to `[]` rather than erroring — old persisted rows and
  forward/backward version skew both read cleanly.
  """

  @enforce_keys [:domain, :type, :seq, :ts]
  defstruct [
    :domain,
    :type,
    :seq,
    :ts,
    :request_id,
    :workflow_id,
    :step_id,
    :session_id,
    :usage,
    :tool,
    raw: %{},
    path: []
  ]

  @type domain :: :llm | :agent | :workflow
  @type llm_type ::
          :request_start
          | :request_stop
          | :reasoning
          | :tool_call
          | :usage
          | :turn_complete
          | :exception
  @type agent_type ::
          :session_open
          | :session_reattach
          | :turn_start
          | :turn_end
          | :terminal
          | :error
  @type workflow_type :: :step_start | :step_stop | :step_exception

  @type t :: %__MODULE__{
          domain: domain(),
          type: llm_type() | agent_type() | workflow_type(),
          seq: non_neg_integer(),
          ts: integer(),
          request_id: String.t() | nil,
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          session_id: String.t() | nil,
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()} | nil,
          tool: %{id: String.t() | nil, name: String.t()} | nil,
          raw: map(),
          path: [String.t()]
        }

  @llm_types ~w(request_start request_stop reasoning tool_call usage turn_complete exception)a
  @agent_types ~w(session_open session_reattach turn_start turn_end terminal error)a
  @workflow_types ~w(step_start step_stop step_exception)a

  @frame_kinds ~w(wf step agent conv)

  @domain_lookup %{"llm" => :llm, "agent" => :agent, "workflow" => :workflow}

  @type_lookup %{
    llm: Map.new(@llm_types, &{Atom.to_string(&1), &1}),
    agent: Map.new(@agent_types, &{Atom.to_string(&1), &1}),
    workflow: Map.new(@workflow_types, &{Atom.to_string(&1), &1})
  }

  @doc """
  Build an `llm.*` event. `type` must be one of `t:llm_type/0`; `attrs` is a
  keyword list or map carrying `:seq` (default `0`), `:ts` (default
  `System.monotonic_time(:nanosecond)`), the four correlation ids, `:usage`,
  `:tool`, `:path` (default `[]` — see the moduledoc), and `:raw` (default
  `%{}`). Returns `{:error, {:bad_frame, frame}}` if any `:path` frame fails
  validation (bad kind, empty id, or non-binary frame).
  """
  @spec llm(llm_type(), keyword() | map()) ::
          {:ok, t()} | {:error, {:bad_type, :llm, term()} | {:bad_frame, term()}}
  def llm(type, attrs), do: build(:llm, @llm_types, type, attrs)

  @doc "Build an `agent.*` event. See `llm/2` for `attrs`."
  @spec agent(agent_type(), keyword() | map()) ::
          {:ok, t()} | {:error, {:bad_type, :agent, term()} | {:bad_frame, term()}}
  def agent(type, attrs), do: build(:agent, @agent_types, type, attrs)

  @doc "Build a `workflow.*` event. See `llm/2` for `attrs`."
  @spec workflow(workflow_type(), keyword() | map()) ::
          {:ok, t()} | {:error, {:bad_type, :workflow, term()} | {:bad_frame, term()}}
  def workflow(type, attrs), do: build(:workflow, @workflow_types, type, attrs)

  defp build(domain, allowed, type, attrs) do
    with true <- type in allowed,
         a = Map.new(attrs),
         :ok <- validate_path(Map.get(a, :path, [])) do
      {:ok, construct(domain, type, a)}
    else
      false -> {:error, {:bad_type, domain, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_path(path) when is_list(path) do
    case Enum.find(path, &(not valid_frame?(&1))) do
      nil -> :ok
      bad -> {:error, {:bad_frame, bad}}
    end
  end

  defp validate_path(other), do: {:error, {:bad_frame, other}}

  defp valid_frame?(frame) when is_binary(frame) do
    case String.split(frame, ":", parts: 2) do
      [kind, id] -> kind in @frame_kinds and id != ""
      _ -> false
    end
  end

  defp valid_frame?(_), do: false

  defp construct(domain, type, attrs) do
    a = Map.new(attrs)

    %__MODULE__{
      domain: domain,
      type: type,
      seq: Map.get(a, :seq, 0),
      ts: Map.get(a, :ts, System.monotonic_time(:nanosecond)),
      request_id: a[:request_id],
      workflow_id: a[:workflow_id],
      step_id: a[:step_id],
      session_id: a[:session_id],
      usage: a[:usage],
      tool: a[:tool],
      path: Map.get(a, :path, []),
      raw: Map.get(a, :raw, %{})
    }
  end

  @doc """
  Render a `t()` to its wire form: a string-keyed map, correlation ids nested
  under `"ids"` (nils omitted, `"ids"` itself always present), `"usage"`/
  `"tool"` present only when not `nil`, `"path"` present only when non-empty,
  `"raw"` always present.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = ev) do
    %{
      "domain" => Atom.to_string(ev.domain),
      "type" => Atom.to_string(ev.type),
      "seq" => ev.seq,
      "ts" => ev.ts,
      "ids" => ids_map(ev),
      "raw" => ev.raw
    }
    |> put_present("usage", wire_usage(ev.usage))
    |> put_present("tool", wire_tool(ev.tool))
    |> maybe_put_path(ev.path)
  end

  defp maybe_put_path(map, []), do: map
  defp maybe_put_path(map, path), do: Map.put(map, "path", path)

  defp ids_map(ev) do
    %{}
    |> put_present("request_id", ev.request_id)
    |> put_present("workflow_id", ev.workflow_id)
    |> put_present("step_id", ev.step_id)
    |> put_present("session_id", ev.session_id)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp wire_usage(nil), do: nil

  defp wire_usage(%{input_tokens: input, output_tokens: output}),
    do: %{"input_tokens" => input, "output_tokens" => output}

  defp wire_tool(nil), do: nil
  defp wire_tool(%{id: id, name: name}), do: %{"id" => id, "name" => name}

  @doc """
  Parse a wire-form map back into a `t()`. Fallible and tolerant: unknown
  top-level keys are ignored, a non-map or a map missing `"domain"`/`"type"`
  is `{:error, {:bad_event, {:invalid_wire, term()}}}`, an unrecognized
  `"domain"` is `{:error, {:bad_event, {:bad_domain, term()}}}`, and an
  unrecognized `"type"` for the domain is `{:error, {:bad_event, {:bad_type,
  domain, term()}}}`. Never raises; never calls `String.to_atom/1`.

  `"path"` is malformed-optional data: a missing key parses to `[]`, and a
  non-list or any element failing frame validation degrades the whole path
  to `[]` rather than failing the parse (a topology hint is never worth
  rejecting an otherwise-valid event over).
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, {:bad_event, term()}}
  def from_wire(%{"domain" => domain_str, "type" => type_str} = wire)
      when is_binary(domain_str) and is_binary(type_str) do
    with {:ok, domain} <- fetch_domain(domain_str),
         {:ok, type} <- fetch_type(domain, type_str) do
      ids = as_map(wire["ids"])

      {:ok,
       construct(domain, type,
         seq: wire["seq"] || 0,
         ts: wire["ts"] || 0,
         request_id: ids["request_id"],
         workflow_id: ids["workflow_id"],
         step_id: ids["step_id"],
         session_id: ids["session_id"],
         usage: parse_usage(wire["usage"]),
         tool: parse_tool(wire["tool"]),
         path: parse_path(wire["path"]),
         raw: as_map(wire["raw"])
       )}
    else
      {:error, reason} -> {:error, {:bad_event, reason}}
    end
  end

  def from_wire(other), do: {:error, {:bad_event, {:invalid_wire, other}}}

  defp fetch_domain(str) do
    case Map.fetch(@domain_lookup, str) do
      {:ok, domain} -> {:ok, domain}
      :error -> {:error, {:bad_domain, str}}
    end
  end

  defp fetch_type(domain, str) do
    case Map.fetch(Map.fetch!(@type_lookup, domain), str) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, {:bad_type, domain, str}}
    end
  end

  defp as_map(m) when is_map(m), do: m
  defp as_map(_), do: %{}

  defp parse_usage(%{"input_tokens" => input, "output_tokens" => output}),
    do: %{input_tokens: input, output_tokens: output}

  defp parse_usage(_), do: nil

  defp parse_tool(%{"name" => name} = t), do: %{id: t["id"], name: name}
  defp parse_tool(_), do: nil

  defp parse_path(path) when is_list(path) do
    if Enum.all?(path, &valid_frame?/1), do: path, else: []
  end

  defp parse_path(_), do: []
end
