defmodule Mimir.Binding.TargetTest do
  use ExUnit.Case, async: true

  alias Mimir.Binding.Target

  test "builds from a map or a keyword list" do
    assert {:ok,
            %Target{
              runtime: "managed",
              configured_model: "anthropic:claude-sonnet-4-6",
              runtime_model: false,
              data_plane: :managed_agents_api
            }} =
             Target.new(%{
               runtime: "managed",
               configured_model: "anthropic:claude-sonnet-4-6",
               runtime_model: false,
               data_plane: :managed_agents_api
             })

    assert {:ok,
            %Target{
              runtime: "custom-runtime",
              configured_model: nil,
              runtime_model: true,
              data_plane: :chat_completions
            }} =
             Target.new(
               runtime: "custom-runtime",
               runtime_model: true,
               data_plane: :chat_completions
             )

    assert {:ok, %Target{configured_model: nil, runtime_model: false, data_plane: :none}} =
             Target.new(
               runtime: "local",
               configured_model: nil,
               runtime_model: false,
               data_plane: :none
             )
  end

  test "names the first invalid field" do
    base = %{runtime: "local", runtime_model: true, data_plane: :none}

    assert Target.new(%{}) == {:error, {:invalid_target, :runtime}}
    assert Target.new(Map.delete(base, :runtime)) == {:error, {:invalid_target, :runtime}}
    assert Target.new(%{base | runtime: ""}) == {:error, {:invalid_target, :runtime}}
    assert Target.new(%{base | runtime: :local}) == {:error, {:invalid_target, :runtime}}

    for model <- ["", :model, %{"modelId" => "model"}] do
      assert Target.new(Map.put(base, :configured_model, model)) ==
               {:error, {:invalid_target, :configured_model}}
    end

    assert Target.new(Map.put(%{base | runtime_model: nil}, :configured_model, "")) ==
             {:error, {:invalid_target, :configured_model}}

    assert Target.new(Map.delete(base, :runtime_model)) ==
             {:error, {:invalid_target, :runtime_model}}

    assert Target.new(%{base | runtime_model: nil}) == {:error, {:invalid_target, :runtime_model}}

    assert Target.new(%{base | runtime_model: "true"}) ==
             {:error, {:invalid_target, :runtime_model}}

    assert Target.new(%{base | runtime_model: nil, data_plane: nil}) ==
             {:error, {:invalid_target, :runtime_model}}

    for plane <- [:messages, true, false, "chat_completions"] do
      assert Target.new(%{base | data_plane: plane}) == {:error, {:invalid_target, :data_plane}}
    end

    assert Target.new(Map.delete(base, :data_plane)) == {:error, {:invalid_target, :data_plane}}
  end

  test "an unknown key is refused, not read as an absent field" do
    base = %{runtime: "local", runtime_model: true, data_plane: :none}

    assert Target.new(Map.put(base, :configured_model_id, "anthropic:claude-haiku-4-5")) ==
             {:error, {:invalid_target, {:unknown_keys, [:configured_model_id]}}}

    assert Target.new(%{"runtime" => "local", :z => nil, :a => nil}) ==
             {:error, {:invalid_target, {:unknown_keys, [:a, :z, "runtime"]}}}

    {:ok, target} = Target.new(base)
    assert Target.new(target) == {:ok, target}

    assert Target.new(%{target | runtime: ""}) == {:error, {:invalid_target, :runtime}}
  end

  test "anything else is not a target" do
    for attrs <- ["local", [1], [{"runtime", "local"}], nil, 42] do
      assert Target.new(attrs) == {:error, {:invalid_target, :not_a_map}}
    end
  end
end
