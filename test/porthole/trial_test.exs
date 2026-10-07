defmodule Porthole.TrialTest do
  use ExUnit.Case, async: true

  alias Porthole.Trial

  @moduletag :tmp_dir

  # A tunnel that logs each start and runs for `seconds`.
  defp tunnel(dir, seconds) do
    path = Path.join(dir, "tunnel")

    File.write!(path, """
    #!/bin/sh
    echo "$$" >> "#{dir}/starts"
    exec sleep #{seconds}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp starts(dir) do
    case File.read(Path.join(dir, "starts")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        :ok

      attempts > 0 ->
        Process.sleep(100)
        eventually(fun, attempts - 1)

      true ->
        flunk("condition never held")
    end
  end

  test "runs the function with the local port and closes the tunnel", %{tmp_dir: dir} do
    result =
      Trial.with_tunnel(tunnel(dir, 60), &["#{&1}"], fn port ->
        eventually(fn -> starts(dir) != [] end)
        port
      end)

    assert is_integer(result)
    [os_pid] = starts(dir)
    eventually(fn -> not alive?(os_pid) end)
  end

  test "reopens a tunnel that exits, up to the limit", %{tmp_dir: dir} do
    Trial.with_tunnel(
      tunnel(dir, 0),
      fn _ -> [] end,
      fn _ ->
        eventually(fn -> length(starts(dir)) == 3 end)
        # No fourth start: reopening waits 1s, so one would show by now.
        Process.sleep(1_500)
        assert length(starts(dir)) == 3
      end,
      2
    )
  end

  test "closes the tunnel when the function raises", %{tmp_dir: dir} do
    assert_raise RuntimeError, fn ->
      Trial.with_tunnel(tunnel(dir, 60), fn _ -> [] end, fn _ ->
        eventually(fn -> starts(dir) != [] end)
        raise "boom"
      end)
    end

    [os_pid] = starts(dir)
    eventually(fn -> not alive?(os_pid) end)
  end
end
