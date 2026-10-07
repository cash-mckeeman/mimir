defmodule MimirOrchestration.Executor.Serialisable do
  @moduledoc """
  The payload's plain-data rule. `check/1` walks every field of the payload,
  descending into lists (improper ones included), tuples and maps (keys and values;
  a struct is walked as its map), and returns the first function, pid, reference or
  port it meets.
  """
  alias MimirOrchestration.Executor.Payload

  @type kind :: :function | :pid | :reference | :port

  @doc """
  `:ok`, or `{:error, {:not_serialisable, path, kind}}`, where `path` lists the keys
  and the list and tuple indexes from the payload root to the term, for example
  `[:run, :extra_args, 0, :owner]`. The `:run` MFA's arguments are under
  `[:run, :extra_args]` and the router's options under `[:router, :opts]`. A banned
  map key is reported at the path of the map that holds it. A keyword list is a list
  of `{key, value}` tuples, so it is walked by index: a pid in
  `router: {module, [owner: pid]}` is at `[:router, :opts, 0, 1]`.
  """
  @spec check(Payload.t()) :: :ok | {:error, {:not_serialisable, [term()], kind()}}
  def check(%Payload{run: run, router: router} = payload) do
    with :ok <- walk_mfa(run, [:run]),
         :ok <- walk_router(router, [:router]) do
      payload |> Map.from_struct() |> Map.drop([:run, :router]) |> walk([])
    end
  end

  defp walk_mfa({m, f, args}, path) when is_atom(m) and is_atom(f) and is_list(args),
    do: walk(args, [:extra_args | path])

  defp walk_mfa(other, path), do: walk(other, path)

  defp walk_router({m, opts}, path) when is_atom(m), do: walk(opts, [:opts | path])
  defp walk_router(other, path), do: walk(other, path)

  defp walk(term, path) when is_function(term), do: refuse(path, :function)
  defp walk(term, path) when is_pid(term), do: refuse(path, :pid)
  defp walk(term, path) when is_reference(term), do: refuse(path, :reference)
  defp walk(term, path) when is_port(term), do: refuse(path, :port)
  defp walk(%_{} = struct, path), do: walk(Map.from_struct(struct), path)

  defp walk(map, path) when is_map(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case walk_entry(key, value, path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp walk(list, path) when is_list(list), do: walk_list(list, 0, path)
  defp walk(tuple, path) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> walk_list(0, path)
  defp walk(_plain, _path), do: :ok

  defp walk_entry(key, value, path) do
    with :ok <- walk(key, path), do: walk(value, [key | path])
  end

  defp walk_list([], _index, _path), do: :ok

  defp walk_list([head | tail], index, path) do
    with :ok <- walk(head, [index | path]), do: walk_list(tail, index + 1, path)
  end

  defp walk_list(improper_tail, index, path), do: walk(improper_tail, [index | path])

  defp refuse(path, kind), do: {:error, {:not_serialisable, Enum.reverse(path), kind}}
end
