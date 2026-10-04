defmodule MimirWorkflows.Template do
  @moduledoc """
  `{{ref}}` extraction and resolution — the IR's dataflow syntax.

  Two ref namespaces: `{{params.name}}` resolves against declared workflow
  params; `{{step_id}}` resolves against upstream step results. A string
  that is exactly one ref substitutes the referenced value **of any type**;
  refs embedded in a longer string interpolate via `to_string/1`.
  Resolution recurses through maps and lists; non-string terms pass
  through untouched.
  """

  @ref_regex ~r/\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}/

  @type ctx :: %{results: map(), params: map()}

  @doc """
  All `{{...}}` refs in a term, recursively through maps and lists.
  Duplicates are preserved (callers count or `Enum.uniq/1` as they need).
  """
  @spec refs(term()) :: [String.t()]
  def refs(term)

  def refs(term) when is_binary(term) do
    @ref_regex
    |> Regex.scan(term, capture: :all_but_first)
    |> List.flatten()
  end

  def refs(term) when is_map(term) and not is_struct(term) do
    Enum.flat_map(term, fn {k, v} -> refs(k) ++ refs(v) end)
  end

  def refs(term) when is_list(term), do: Enum.flat_map(term, &refs/1)
  def refs(_term), do: []

  @doc """
  Resolves every ref in `template` against `ctx`; the first missing ref
  short-circuits as `{:error, {:unresolved_ref, ref}}`.
  """
  @spec resolve(term(), ctx()) :: {:ok, term()} | {:error, {:unresolved_ref, String.t()}}
  def resolve(template, ctx) do
    {:ok, do_resolve(template, ctx)}
  catch
    {:unresolved_ref, ref} -> {:error, {:unresolved_ref, ref}}
  end

  # ---------------------------------------------------------------------------

  defp do_resolve(term, ctx) when is_binary(term) do
    case whole_ref(term) do
      {:ok, ref} ->
        lookup!(ref, ctx)

      :no ->
        Regex.replace(@ref_regex, term, fn _whole, ref ->
          to_string(lookup!(ref, ctx))
        end)
    end
  end

  defp do_resolve(term, ctx) when is_map(term) and not is_struct(term) do
    Map.new(term, fn {k, v} -> {do_resolve(k, ctx), do_resolve(v, ctx)} end)
  end

  defp do_resolve(term, ctx) when is_list(term), do: Enum.map(term, &do_resolve(&1, ctx))
  defp do_resolve(term, _ctx), do: term

  defp whole_ref(string) do
    case Regex.run(~r/\A\{\{\s*([a-zA-Z0-9_.]+)\s*\}\}\z/, String.trim(string),
           capture: :all_but_first
         ) do
      [ref] -> {:ok, ref}
      nil -> :no
    end
  end

  defp lookup!("params." <> name, ctx) do
    case Map.fetch(ctx.params, name) do
      {:ok, value} -> value
      :error -> throw({:unresolved_ref, "params.#{name}"})
    end
  end

  defp lookup!(ref, ctx) do
    case Map.fetch(ctx.results, ref) do
      {:ok, value} -> value
      :error -> throw({:unresolved_ref, ref})
    end
  end
end
