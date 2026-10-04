defmodule Mimir.Descriptor do
  @moduledoc """
  The workload descriptor — the public contract a workflow step presents to a
  routing oracle. Pure validation: no persistence, no process state.

  `quality_bar` is reserved for eval-scored routing; a non-nil value is
  REJECTED (not ignored) until scorecards exist.

  `agent` is optional correlation identity for the caller: a content digest
  plus an optional display name/version, carried through as plain data (e.g.
  into decision records) without the descriptor needing to know what an
  "agent" is beyond that shape.

  `max_outcome_iterations` is a budget hint for outcome-evaluated sessions —
  an outcome session may revise its answer up to that many times before
  settling, so budget-scaling layers can widen ceilings for it the same way
  they do for fan-out hints.
  """

  @capabilities [:tools, :vision, :long_context]
  @runtime_prefs [:any, :managed, :local]

  @enforce_keys [:task_class, :budget_ceiling_microdollars, :latency_tolerance_ms]
  defstruct [
    :task_class,
    :budget_ceiling_microdollars,
    :latency_tolerance_ms,
    :expected_tokens,
    :quality_bar,
    :agent,
    :max_outcome_iterations,
    capabilities: [],
    runtime_preference: :any
  ]

  @type capability :: :tools | :vision | :long_context
  @type runtime_preference :: :any | :managed | :local
  @type agent_identity :: %{
          digest: String.t(),
          name: String.t() | nil,
          version: String.t() | nil
        }
  @type expected_tokens :: %{in: non_neg_integer(), out: non_neg_integer()}

  @type t :: %__MODULE__{
          task_class: String.t(),
          budget_ceiling_microdollars: pos_integer(),
          latency_tolerance_ms: pos_integer(),
          expected_tokens: expected_tokens() | nil,
          quality_bar: nil,
          agent: agent_identity() | nil,
          max_outcome_iterations: pos_integer() | nil,
          capabilities: [capability()],
          runtime_preference: runtime_preference()
        }

  @doc """
  Validate and build a `t()` from a plain map. Accepts atom or string keys.
  Rejects a non-nil `quality_bar` and any unknown capability/runtime-preference
  value rather than silently dropping it.
  """
  @spec parse(map()) ::
          {:ok, t()}
          | {:error, {:invalid_descriptor, atom(), String.t()}}
          | {:error, :quality_bar_unsupported}
  def parse(input) when is_map(input) do
    get = fn key -> Map.get(input, key, Map.get(input, to_string(key))) end

    with :ok <- reject_quality_bar(get.(:quality_bar)),
         {:ok, task_class} <- require_binary(:task_class, get.(:task_class)),
         {:ok, budget} <-
           require_pos_int(:budget_ceiling_microdollars, get.(:budget_ceiling_microdollars)),
         {:ok, latency} <- require_pos_int(:latency_tolerance_ms, get.(:latency_tolerance_ms)),
         {:ok, caps} <- parse_capabilities(get.(:capabilities) || []),
         {:ok, pref} <- parse_pref(get.(:runtime_preference) || :any),
         {:ok, tokens} <- parse_tokens(get.(:expected_tokens)),
         {:ok, agent} <- parse_agent(get.(:agent)),
         {:ok, outcome_iters} <- parse_outcome_iterations(get.(:max_outcome_iterations)) do
      {:ok,
       %__MODULE__{
         task_class: task_class,
         budget_ceiling_microdollars: budget,
         latency_tolerance_ms: latency,
         capabilities: caps,
         runtime_preference: pref,
         expected_tokens: tokens,
         quality_bar: nil,
         agent: agent,
         max_outcome_iterations: outcome_iters
       }}
    end
  end

  defp reject_quality_bar(nil), do: :ok
  defp reject_quality_bar(_), do: {:error, :quality_bar_unsupported}

  defp require_binary(_field, v) when is_binary(v) and v != "", do: {:ok, v}

  defp require_binary(field, _),
    do: {:error, {:invalid_descriptor, field, "required non-empty string"}}

  defp require_pos_int(_field, v) when is_integer(v) and v > 0, do: {:ok, v}

  defp require_pos_int(field, _),
    do: {:error, {:invalid_descriptor, field, "required positive integer"}}

  defp parse_capabilities(caps) when is_list(caps) do
    parsed = Enum.map(caps, &to_existing_capability/1)

    case Enum.find(parsed, &match?(:error, &1)) do
      nil ->
        {:ok, Enum.map(parsed, fn {:ok, c} -> c end)}

      _ ->
        {:error, {:invalid_descriptor, :capabilities, "unknown capability in #{inspect(caps)}"}}
    end
  end

  defp parse_capabilities(other),
    do: {:error, {:invalid_descriptor, :capabilities, "expected list, got #{inspect(other)}"}}

  defp to_existing_capability(c) when is_atom(c) and c in @capabilities, do: {:ok, c}

  defp to_existing_capability(c) when is_binary(c) do
    # Closed vocabulary — no String.to_atom on user input.
    Enum.find_value(@capabilities, :error, fn known ->
      if Atom.to_string(known) == c, do: {:ok, known}
    end)
  end

  defp to_existing_capability(_), do: :error

  defp parse_pref(p) when p in @runtime_prefs, do: {:ok, p}

  defp parse_pref(p) when is_binary(p) do
    Enum.find_value(
      @runtime_prefs,
      {:error, {:invalid_descriptor, :runtime_preference, "unknown: #{p}"}},
      fn known ->
        if Atom.to_string(known) == p, do: {:ok, known}
      end
    )
  end

  defp parse_pref(p),
    do: {:error, {:invalid_descriptor, :runtime_preference, "unknown: #{inspect(p)}"}}

  defp parse_tokens(nil), do: {:ok, nil}

  defp parse_tokens(%{} = t) do
    input = t[:in] || t["in"]
    output = t[:out] || t["out"]

    if is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
      {:ok, %{in: input, out: output}}
    else
      {:error, {:invalid_descriptor, :expected_tokens, "expected %{in: n>=0, out: n>=0}"}}
    end
  end

  defp parse_tokens(other),
    do: {:error, {:invalid_descriptor, :expected_tokens, "expected map, got #{inspect(other)}"}}

  defp parse_agent(nil), do: {:ok, nil}

  defp parse_agent(%{} = a) do
    digest = a[:digest] || a["digest"]

    if is_binary(digest) and digest != "" do
      {:ok, %{digest: digest, name: a[:name] || a["name"], version: a[:version] || a["version"]}}
    else
      {:error, {:invalid_descriptor, :agent, "expected %{digest: non-empty string, ...}"}}
    end
  end

  defp parse_agent(other),
    do: {:error, {:invalid_descriptor, :agent, "expected map, got #{inspect(other)}"}}

  defp parse_outcome_iterations(nil), do: {:ok, nil}
  defp parse_outcome_iterations(n) when is_integer(n) and n > 0, do: {:ok, n}

  defp parse_outcome_iterations(other),
    do:
      {:error,
       {:invalid_descriptor, :max_outcome_iterations,
        "expected positive integer, got #{inspect(other)}"}}
end
