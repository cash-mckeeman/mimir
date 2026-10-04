# Run in a fresh `mix run` OS process (see guard_test.exs), never inside
# the shared `mix test` VM: it mutates the global code path, which would
# be a flaky, VM-wide side effect if run alongside async tests.
#
# Reproduces an ArgumentError that has nothing to do with pricing config:
# Application.app_dir(:mimir, …) raises "unknown application: :mimir"
# once mimir's own code is off the VM's load path, the shape of failure
# a stripped or escript-style build can hit. Prints "PROBE_OK: <message>"
# and exits 0 if Mimir.Guard lets that raise propagate (the desired
# behavior); otherwise prints "PROBE_FAIL: <result>" and exits 1.

Code.ensure_loaded!(Mimir.Pricing)
Code.ensure_loaded!(Mimir.Guard)
Code.ensure_loaded!(Mimir.Grant)
Code.ensure_loaded!(Mimir.Pricing.InvalidConfigError)

ebin =
  :mimir
  |> :code.lib_dir()
  |> to_string()
  |> Path.join("ebin")
  |> String.to_charlist()

:code.del_path(ebin)

guard =
  Mimir.Guard.for_grant(%Mimir.Grant{key: "vk", budget_microdollars: 1_000}, "unrelated:model")

result =
  try do
    guard.(%{usage: %{input_tokens: 1, output_tokens: 1}, turns: 1})
    :no_raise
  rescue
    e in ArgumentError -> {:raised_argument_error, Exception.message(e)}
    other -> {:raised_other, other}
  end

:code.add_pathz(ebin)

case result do
  {:raised_argument_error, msg} ->
    IO.puts("PROBE_OK: #{msg}")
    System.halt(0)

  other ->
    IO.puts("PROBE_FAIL: #{inspect(other)}")
    System.halt(1)
end
