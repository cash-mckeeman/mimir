defmodule MimirWorkflows.Spec do
  @moduledoc """
  The parsed workflow IR.

  Workflow specs arrive as **string-keyed maps** (they may come off a wire
  or out of a model) and parse into `%Spec{}`/`%Spec.Step{}` structs whose
  step ids **stay strings** — untrusted IR never mints atoms. `parse/1` is
  best-effort: it always returns a struct alongside accumulated `:schema`
  diagnostics rather than raising, so later compiler passes can still run
  and report their own findings.

  The library validates universal shape only. `"kind"` vocabulary — and
  anything else domain-shaped in a step map — is host concern; the full
  original step map is preserved in `raw`.
  """

  alias MimirWorkflows.Diagnostic

  defmodule Step do
    @moduledoc """
    One parsed IR step. `raw` carries the complete original map — the
    library never strips host fields.
    """

    @type t :: %__MODULE__{
            id: String.t() | nil,
            kind: String.t() | nil,
            depends_on: [String.t()],
            raw: map()
          }

    defstruct id: nil, kind: nil, depends_on: [], raw: %{}
  end

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: integer() | nil,
          params: [String.t()],
          steps: [Step.t()]
        }

  defstruct name: nil, version: nil, params: [], steps: []

  @doc """
  Parses a string-keyed spec map into `{%Spec{}, [Diagnostic.t()]}`.

  Every violation appends a `%Diagnostic{pass: :schema, severity: :error}`;
  the struct is always returned (steps without ids are kept with
  `id: nil` so later passes can skip them).
  """
  @spec parse(map()) :: {t(), [Diagnostic.t()]}
  def parse(map) when is_map(map) do
    {name, diags} = required_string(map, "name", [])
    {version, diags} = required_integer(map, "version", diags)
    {params, diags} = optional_string_list(map, "params", diags)
    {steps, diags} = parse_steps(Map.get(map, "steps"), diags)

    {%__MODULE__{name: name, version: version, params: params, steps: steps}, Enum.reverse(diags)}
  end

  # ---------------------------------------------------------------------------

  defp required_string(map, key, diags) do
    case Map.get(map, key) do
      v when is_binary(v) -> {v, diags}
      nil -> {nil, [schema_error(nil, ~s(missing "#{key}")) | diags]}
      _ -> {nil, [schema_error(nil, ~s("#{key}" must be a string)) | diags]}
    end
  end

  defp required_integer(map, key, diags) do
    case Map.get(map, key) do
      v when is_integer(v) -> {v, diags}
      nil -> {nil, [schema_error(nil, ~s(missing "#{key}")) | diags]}
      _ -> {nil, [schema_error(nil, ~s("#{key}" must be an integer)) | diags]}
    end
  end

  defp optional_string_list(map, key, diags) do
    case Map.get(map, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {list, diags}
        else
          {Enum.filter(list, &is_binary/1),
           [schema_error(nil, ~s("#{key}" must be a list of strings)) | diags]}
        end

      _ ->
        {[], [schema_error(nil, ~s("#{key}" must be a list)) | diags]}
    end
  end

  defp parse_steps(steps, diags) when is_list(steps) do
    {parsed, diags} =
      steps
      |> Enum.with_index()
      |> Enum.reduce({[], diags}, fn {raw, idx}, {acc, diags} ->
        {step, diags} = parse_step(raw, idx, diags)
        {[step | acc], diags}
      end)

    parsed = Enum.reverse(parsed)

    dup_diags =
      parsed
      |> Enum.map(& &1.id)
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, n} -> n > 1 end)
      |> Enum.map(fn {id, _n} -> schema_error(id, ~s(duplicate id "#{id}")) end)

    {parsed, dup_diags ++ diags}
  end

  defp parse_steps(nil, diags), do: {[], [schema_error(nil, ~s(missing "steps")) | diags]}
  defp parse_steps(_, diags), do: {[], [schema_error(nil, ~s("steps" must be a list)) | diags]}

  defp parse_step(raw, idx, diags) when is_map(raw) do
    {id, diags} = step_string_field(raw, "id", nil, idx, diags)
    {kind, diags} = step_string_field(raw, "kind", id, idx, diags)
    {deps, diags} = step_deps(raw, id, idx, diags)

    {%Step{id: id, kind: kind, depends_on: deps, raw: raw}, diags}
  end

  defp parse_step(_raw, idx, diags) do
    {%Step{raw: %{}}, [schema_error(nil, "step #{idx}: must be a map") | diags]}
  end

  defp step_string_field(raw, key, blame_id, idx, diags) do
    case Map.get(raw, key) do
      v when is_binary(v) -> {v, diags}
      nil -> {nil, [schema_error(blame_id, ~s(step #{idx}: missing "#{key}")) | diags]}
      _ -> {nil, [schema_error(blame_id, ~s(step #{idx}: "#{key}" must be a string)) | diags]}
    end
  end

  defp step_deps(raw, id, idx, diags) do
    case Map.get(raw, "depends_on", []) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {list, diags}
        else
          {Enum.filter(list, &is_binary/1),
           [schema_error(id, ~s(step #{idx}: "depends_on" entries must be strings)) | diags]}
        end

      _ ->
        {[], [schema_error(id, ~s(step #{idx}: "depends_on" must be a list)) | diags]}
    end
  end

  defp schema_error(step_id, message) do
    %Diagnostic{pass: :schema, severity: :error, step_id: step_id, message: message}
  end
end
