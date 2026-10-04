defmodule MimirWorkflows.Compiler do
  @moduledoc """
  Compiles a string-keyed workflow spec map into a validated `%Spec{}`.

  Built-in passes — `:schema` (shape, via `Spec.parse/1`), `:dag`
  (dependencies exist, graph is acyclic), `:refs` (every `{{ref}}`
  resolves to a declared param or a declared dependency) — run first;
  host passes (`MimirWorkflows.Compiler.Pass`) append after them. **All
  passes run even after failures and diagnostics accumulate**, so a
  caller (or an agent repairing its own plan) sees every problem in one
  round trip. The result is `{:error, diagnostics}` iff any diagnostic is
  `severity: :error`; otherwise `{:ok, spec, warnings}`.
  """

  alias MimirWorkflows.{Dag, Diagnostic, Spec, Template}

  @doc """
  Compiles `spec_map` with the built-in passes plus `opts[:passes]`, a
  list of `{module, ctx}` implementing `MimirWorkflows.Compiler.Pass`.
  """
  @spec compile(map(), keyword()) ::
          {:ok, Spec.t(), [Diagnostic.t()]} | {:error, [Diagnostic.t()]}
  def compile(spec_map, opts \\ []) when is_map(spec_map) do
    {spec, schema_diags} = Spec.parse(spec_map)

    diags =
      schema_diags ++
        dag_pass(spec) ++
        refs_pass(spec) ++
        host_passes(spec, Keyword.get(opts, :passes, []))

    case Enum.split_with(diags, &(&1.severity == :error)) do
      {[], warnings} -> {:ok, spec, warnings}
      {_errors, _} -> {:error, diags}
    end
  end

  # ---------------------------------------------------------------------------

  defp dag_pass(%Spec{steps: steps}) do
    steps
    |> Enum.reject(&is_nil(&1.id))
    |> Enum.map(&%{id: &1.id, depends_on: &1.depends_on})
    |> Dag.waves()
    |> case do
      {:ok, _phases} ->
        []

      {:error, :cyclic} ->
        [
          %Diagnostic{
            pass: :dag,
            severity: :error,
            step_id: nil,
            message: "dependency graph contains a cycle"
          }
        ]

      {:error, {:unknown_dependency, dep}} ->
        for step <- steps, dep in step.depends_on do
          %Diagnostic{
            pass: :dag,
            severity: :error,
            step_id: step.id,
            message: ~s(unknown dependency "#{dep}")
          }
        end
    end
  end

  defp refs_pass(%Spec{steps: steps, params: params}) do
    param_set = MapSet.new(params)

    Enum.flat_map(steps, fn
      %Spec.Step{id: nil} ->
        []

      step ->
        deps = MapSet.new(step.depends_on)

        step.raw
        |> Template.refs()
        |> Enum.uniq()
        |> Enum.flat_map(&check_ref(&1, step.id, deps, param_set))
    end)
  end

  defp check_ref("params." <> name, step_id, _deps, param_set) do
    if MapSet.member?(param_set, name) do
      []
    else
      [refs_error(step_id, ~s({{params.#{name}}} is not a declared param))]
    end
  end

  defp check_ref(ref, step_id, deps, _param_set) do
    if MapSet.member?(deps, ref) do
      []
    else
      [refs_error(step_id, ~s({{#{ref}}} is not covered by "depends_on"))]
    end
  end

  defp refs_error(step_id, message) do
    %Diagnostic{pass: :refs, severity: :error, step_id: step_id, message: message}
  end

  defp host_passes(spec, passes) do
    Enum.flat_map(passes, fn {module, ctx} -> module.check(spec, ctx) end)
  end
end
