defmodule Integration.ExecutionBindingHTTP do
  @moduledoc false

  def expect(bypass, owner, counter, path) do
    Bypass.expect_once(bypass, "POST", path, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      Agent.update(counter, &(&1 + 1))

      send(
        owner,
        {:wire, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), body["model"]}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "chat-test",
          "object" => "chat.completion",
          "created" => 1,
          "model" => body["model"],
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => "ok"},
              "finish_reason" => "stop"
            }
          ],
          "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16}
        })
      )
    end)
  end
end
