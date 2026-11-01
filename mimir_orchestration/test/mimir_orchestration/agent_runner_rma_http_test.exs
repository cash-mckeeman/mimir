defmodule MimirOrchestration.AgentRunner.RMAHTTPTest do
  use ExUnit.Case, async: true
  @moduletag :rma

  if Code.ensure_loaded?(ReqManagedAgents) and Code.ensure_loaded?(ReqLLM) do
    alias MimirOrchestration.AgentRunner.RMA
    alias MimirOrchestration.AgentRunner.RMA.Reference

    test "the default Local adapter sends the configured request with the installed HTTP stack" do
      owner = self()
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_, port}} = :inet.sockname(listener)

      start_supervised!({Task, fn -> serve(listener, owner) end})

      {:ok, reference} =
        Reference.new(
          provider: ReqManagedAgents.Providers.Local,
          runtime: "local",
          resource: {:handle, %{spec: %{system_prompt: "brief"}}}
        )

      assert {:ok, result} =
               RMA.run(reference, "q",
                 model_config: %{
                   model: "fixture:model",
                   api_key: "fixture-key",
                   base_url: "http://127.0.0.1:#{port}/v1"
                 },
                 handler: fn _, _, _ -> {:error, :unexpected_tool} end,
                 max_turns: 1,
                 timeout: 1_000
               )

      assert result.text == "ok"
      assert result.usage["input_tokens"] == 3
      assert result.usage["output_tokens"] == 1
      assert_received {:wire, headers, %{"model" => "fixture:model"}}
      assert headers =~ "POST /v1/chat/completions HTTP/1.1"
      assert String.downcase(headers) =~ "authorization: bearer fixture-key"
      refute_received {:wire, _, _}
    end

    defp serve(listener, owner) do
      {:ok, socket} = :gen_tcp.accept(listener)
      {headers, body} = read_headers(socket, "")
      [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
      body = read_body(socket, body, String.to_integer(length))
      send(owner, {:wire, headers, Jason.decode!(body)})

      response =
        Jason.encode!(%{
          id: "fixture", object: "chat.completion", created: 1, model: "fixture:model",
          choices: [%{index: 0, message: %{role: "assistant", content: "ok"}, finish_reason: "stop"}],
          usage: %{prompt_tokens: 3, completion_tokens: 1, total_tokens: 4}
        })

      :ok = :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\ncontent-length: ",
        Integer.to_string(byte_size(response)), "\r\n\r\n", response
      ])
      :gen_tcp.close(socket)
    end

    defp read_headers(socket, acc) do
      case String.split(acc, "\r\n\r\n", parts: 2) do
        [headers, rest] -> {headers, rest}
        [_] ->
          {:ok, more} = :gen_tcp.recv(socket, 0, 1_000)
          read_headers(socket, acc <> more)
      end
    end

    defp read_body(_socket, acc, length) when byte_size(acc) >= length, do: acc
    defp read_body(socket, acc, length) do
      {:ok, more} = :gen_tcp.recv(socket, 0, 1_000)
      read_body(socket, acc <> more, length)
    end
  end
end
