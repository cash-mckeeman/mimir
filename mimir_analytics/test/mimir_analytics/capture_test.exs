defmodule MimirAnalytics.CaptureTest do
  use ExUnit.Case, async: true

  alias MimirAnalytics.Capture

  @result %{"terminal" => "end_turn", "session_id" => "sess_x", "turns" => 2}
  @meta %{"workflow_id" => "wf_1", "runtime" => "local"}

  @tag :tmp_dir
  test "each write publishes its own one-line file", %{tmp_dir: dir} do
    {:ok, path} = Capture.write(@result, @meta, dir)
    {:ok, path2} = Capture.write(@result, @meta, dir)

    assert path != path2

    for p <- [path, path2] do
      assert Path.dirname(p) == dir
      assert Path.extname(p) == ".jsonl"
      assert [line] = p |> File.read!() |> String.split("\n", trim: true)
      assert %{"meta" => @meta, "result" => @result} = Jason.decode!(line)
    end
  end

  @tag :tmp_dir
  test "leaves no temporary file behind", %{tmp_dir: dir} do
    {:ok, path} = Capture.write(@result, @meta, dir)

    assert File.ls!(dir) == [Path.basename(path)]
  end
end
