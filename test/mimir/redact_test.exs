defmodule Mimir.RedactTest do
  use ExUnit.Case, async: true
  alias Mimir.Redact

  test "payloads are dropped when logging is disabled (default)" do
    out =
      Redact.payloads(
        %{messages: [%{"content" => "secret vk-ABC123"}]},
        %{"choices" => []},
        false
      )

    assert out == {nil, nil}
  end

  test "payloads pass through (redacted shape) when enabled" do
    {req, _resp} = Redact.payloads(%{messages: [%{"role" => "user"}]}, %{}, true)
    assert is_map(req)
  end

  test "truncate caps bytes and never splits a multi-byte UTF-8 char" do
    # "你好世界" is 12 bytes (3 bytes/char). A byte cap of 8 lands mid-character.
    s = "你好世界"
    out = Redact.truncate(s, 8)

    assert byte_size(out) <= 8
    assert String.valid?(out), "truncation must return valid UTF-8, got #{inspect(out)}"
    assert out == "你好"
  end

  test "truncate leaves a short binary untouched and passes non-binaries through" do
    assert Redact.truncate("ok", 500) == "ok"
    assert Redact.truncate(nil, 500) == nil
  end

  test "captured payloads scrub known secret patterns (vk-, sk-)" do
    {req, _resp} =
      Redact.payloads(%{messages: [%{"content" => "key vk-LEAK and sk-PROVIDERKEY"}]}, %{}, true)

    json = Jason.encode!(req)
    refute String.contains?(json, "vk-LEAK")
    refute String.contains?(json, "sk-PROVIDERKEY")
    assert String.contains?(json, "[REDACTED]")
  end

  test "split_provider splits on colon and handles edge cases" do
    assert Redact.split_provider("bedrock:nvidia.nemotron-super-3-120b") ==
             {"bedrock", "nvidia.nemotron-super-3-120b"}

    assert Redact.split_provider("claude-3") == {nil, "claude-3"}
    assert Redact.split_provider("") == {nil, nil}
  end
end
