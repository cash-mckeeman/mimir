defmodule MimirOrchestration.AgentRunner.RMAReferenceTest do
  use ExUnit.Case, async: true

  alias MimirOrchestration.AgentRunner.RMA.Reference

  test "specs and handles retain opaque resources and exact host declarations" do
    for resource <- [{:spec, %{name: "agent"}}, {:handle, "resource-id"}] do
      attrs = [provider: UnloadedProvider, runtime: "host-runtime", resource: resource]
      assert {:ok, ref} = Reference.new(attrs)
      assert ref.provider == UnloadedProvider
      assert ref.runtime == "host-runtime"
      assert ref.resource == resource
      assert ref.configured_model == nil
      assert {:ok, ^ref} = Reference.new(Map.new(attrs))
      assert {:ok, ^ref} = Reference.new(ref)
    end
  end

  test "accepts an unavailable provider atom without requiring provider capabilities" do
    refute Code.ensure_loaded?(UnavailableRuntimeProvider)

    assert {:ok, ref} =
             Reference.new(
               provider: UnavailableRuntimeProvider,
               runtime: "local",
               resource: {:handle, %{}}
             )

    assert ref.provider == UnavailableRuntimeProvider
  end

  test "reference construction rejects duplicate and unknown keys" do
    attrs = valid()

    assert {:error, {:invalid_agent_reference, :keys}} =
             Reference.new(attrs ++ [runtime: "other"])

    assert {:error, {:invalid_agent_reference, :keys}} =
             Reference.new(attrs ++ [extra: true])

    assert {:error, {:invalid_agent_reference, :keys}} =
             Reference.new(Map.put(Map.new(attrs), "runtime", "other"))
  end

  test "required provider is an atom other than nil or a boolean" do
    for provider <- [nil, true, false, "Provider", 42] do
      assert {:error, {:invalid_agent_reference, :provider}} =
               Reference.new(Keyword.put(valid(), :provider, provider))
    end

    assert {:error, {:invalid_agent_reference, :provider}} =
             Reference.new(Keyword.delete(valid(), :provider))
  end

  test "runtime is required and a configured catalog model must be nonempty" do
    for runtime <- [nil, "", :local, 42] do
      assert {:error, {:invalid_agent_reference, :runtime}} =
               Reference.new(Keyword.put(valid(), :runtime, runtime))
    end

    for model <- ["", :model, 42] do
      assert {:error, {:invalid_agent_reference, :configured_model}} =
               Reference.new(valid() ++ [configured_model: model])
    end

    assert {:ok, ref} = Reference.new(valid() ++ [configured_model: "anthropic:model"])
    assert ref.configured_model == "anthropic:model"
  end

  test "resource tag is closed while its provider-owned contents remain opaque" do
    for resource <- [nil, %{}, {:other, "id"}, {:handle}, {:spec, "id", :extra}] do
      assert {:error, {:invalid_agent_reference, :resource}} =
               Reference.new(Keyword.put(valid(), :resource, resource))
    end

    opaque = %{provider_process: self(), callback: fn -> :ok end}
    assert {:ok, ref} = Reference.new(Keyword.put(valid(), :resource, {:handle, opaque}))
    assert ref.resource == {:handle, opaque}
  end

  test "an existing struct is revalidated" do
    assert {:ok, ref} = Reference.new(valid())

    assert {:error, {:invalid_agent_reference, :runtime}} =
             Reference.new(%{ref | runtime: ""})
  end

  test "non-map and non-keyword inputs return a tagged reference error" do
    for input <- [nil, "reference", :provider, 12, ["invalid"], {:provider, {:handle, "id"}}] do
      assert {:error, {:invalid_agent_reference, :reference}} = Reference.new(input)
    end
  end

  defp valid, do: [provider: UnloadedProvider, runtime: "local", resource: {:handle, "id"}]
end
