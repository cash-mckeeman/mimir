defmodule Mimir.Redact do
  @moduledoc """
  Helpers for masking secrets and gating payload capture.

  Provides utilities to safely mask sensitive information in data structures
  and to conditionally enable/disable payload capture to prevent secret leaks.
  """

  @doc """
  Splits a `"provider:model_id"` model string into `{provider, model_id}`.
  If there is no `:` separator, returns `{nil, model}`.

      iex> Redact.split_provider("bedrock:nvidia.nemotron-super-3-120b")
      {"bedrock", "nvidia.nemotron-super-3-120b"}

      iex> Redact.split_provider("claude-3")
      {nil, "claude-3"}
  """
  @spec split_provider(String.t()) :: {String.t() | nil, String.t() | nil}
  # No model at all (e.g. a route-decision row) — both columns stay nil.
  def split_provider(""), do: {nil, nil}

  def split_provider(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, model_id] -> {provider, model_id}
      [model_id] -> {nil, model_id}
    end
  end

  def split_provider(_), do: {nil, nil}

  @doc """
  Truncates a binary to at most `max` bytes, UTF-8-safely: if the byte cut lands
  mid-character, the trailing incomplete sequence is dropped so the result is
  always valid UTF-8 (and still ≤ `max` bytes). Non-binaries pass through.
  """
  @spec truncate(binary(), non_neg_integer()) :: binary()
  def truncate(bin, max) when is_binary(bin) and byte_size(bin) <= max, do: bin

  def truncate(bin, max) when is_binary(bin) do
    bin |> binary_part(0, max) |> trim_to_valid_utf8()
  end

  def truncate(other, _max), do: other

  # Drop up to 3 trailing bytes (UTF-8 chars are ≤ 4 bytes) until the binary is
  # valid UTF-8 again. Empty is valid, so this always terminates.
  defp trim_to_valid_utf8(bin) do
    if String.valid?(bin) do
      bin
    else
      trim_to_valid_utf8(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end

  @doc """
  Gate payload capture. Returns `{request_payload, response_payload}`.

  When `enabled?` is false (the default), returns `{nil, nil}` — message content
  is never persisted, so no secrets can leak through the payload columns. When
  true, returns the payloads as maps (the gated path); scalar metadata is always
  safe and is captured regardless.
  """
  @spec payloads(map() | nil, map() | nil, boolean()) :: {map() | nil, map() | nil}
  def payloads(_request, _response, false), do: {nil, nil}

  def payloads(request, response, true),
    do: {scrub(as_payload(request)), scrub(as_payload(response))}

  defp as_payload(%_{} = struct), do: Map.from_struct(struct)
  defp as_payload(map) when is_map(map), do: map
  defp as_payload(_), do: nil

  # Known secret patterns scrubbed from captured payloads. Capture turns payload
  # persistence ON for a subset of traffic, so the enabled path MUST redact
  # secrets (the off path simply drops payloads). Patterns: gateway virtual keys
  # (vk-), OpenAI/Anthropic-style provider keys (sk-), AWS access key ids (AKIA),
  # Google API keys (AIza).
  @secret_patterns [
    ~r/vk-[A-Za-z0-9_\-]+/,
    ~r/sk-[A-Za-z0-9_\-]+/,
    ~r/AKIA[0-9A-Z]{8,}/,
    ~r/AIza[0-9A-Za-z_\-]{10,}/
  ]
  @redacted "[REDACTED]"

  # Recursively replace known secret patterns in any string within a payload.
  defp scrub(nil), do: nil
  defp scrub(%_{} = struct), do: scrub(Map.from_struct(struct))
  defp scrub(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, scrub(v)} end)
  defp scrub(list) when is_list(list), do: Enum.map(list, &scrub/1)

  defp scrub(s) when is_binary(s) do
    Enum.reduce(@secret_patterns, s, fn re, acc -> Regex.replace(re, acc, @redacted) end)
  end

  defp scrub(other), do: other
end
