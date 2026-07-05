defmodule Mimir.CatalogTest do
  # async: false — entries/0 test writes to global Application env via
  # Application.put_env; running async risks reading stale/dirty env in
  # other tests that call Application.get_env(:mimir, :catalog).
  use ExUnit.Case, async: false
  alias Mimir.Catalog

  @config [
    %{
      id: "sonnet-managed",
      model: "known:model",
      lane: "anthropic",
      runtime: :managed,
      capabilities: [:tools, :vision],
      p50_latency_ms: 4_000,
      priority: 10
    },
    %{
      id: "nemotron-local",
      model: "known:other",
      lane: "ollama",
      runtime: :local,
      capabilities: [:tools],
      p50_latency_ms: 9_000,
      priority: 20
    }
  ]

  defp resolve(m) when m in ["known:model", "known:other"], do: {:ok, :spec}
  defp resolve(_m), do: {:error, :unknown_model}

  test "builds entries with resolved specs from explicit config" do
    entries = Catalog.entries(@config, resolve: &resolve/1)

    assert [
             %Catalog.Entry{
               id: "sonnet-managed",
               model_spec: :spec,
               capabilities: [:tools, :vision],
               p50_latency_ms: 4_000,
               priority: 10
             }
             | _
           ] = entries
  end

  test "an entry whose model fails resolution is dropped with a logged warning" do
    import ExUnit.CaptureLog

    bad = [
      %{
        id: "bad",
        model: "nope",
        lane: "x",
        runtime: :local,
        capabilities: [],
        p50_latency_ms: 1,
        priority: 1
      }
    ]

    log = capture_log(fn -> assert Catalog.entries(bad, resolve: &resolve/1) == [] end)
    assert log =~ "catalog entry dropped"
  end

  test "entries/0 reads app config" do
    Application.put_env(:mimir, :catalog, @config)
    on_exit(fn -> Application.delete_env(:mimir, :catalog) end)
    assert length(Catalog.entries(nil, resolve: &resolve/1)) == 2
  end

  test "default resolver is identity (gateway-less mode)" do
    entries =
      Mimir.Catalog.entries([%{id: "e1", model: "ollama:qwen3", lane: "local", runtime: "local"}])

    assert [%Mimir.Catalog.Entry{model_spec: "ollama:qwen3"}] = entries
  end
end
