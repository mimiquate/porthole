defmodule Porthole.FlyTest do
  @moduledoc """
  `mix porthole.fly.up` / `fly.down` against a fake `fly` that answers from
  canned responses and records its calls. These cover the checks that must
  stop before anything is created or destroyed. The full flow needs real
  machines; it was verified by hand with a `fly` stand-in backed by Docker.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @cookie "secret-cookie-value"

  setup do
    dir = Path.join(System.tmp_dir!(), "porthole-fly-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fly = Path.join(dir, "fly")

    # $FAKE_DIR/<subcommand> holds the answer to `fly <subcommand> ...`.
    File.write!(fly, ~S"""
    #!/bin/sh
    echo "$*" >> "$FAKE_DIR/calls"
    answer="$FAKE_DIR/$1-$2"
    [ -f "$answer" ] || { echo "unexpected: fly $*" >&2; exit 2; }
    cat "$answer"
    """)

    File.chmod!(fly, 0o755)
    System.put_env(%{"PORTHOLE_FLY" => fly, "FAKE_DIR" => dir})
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      System.delete_env("PORTHOLE_FLY")
      System.delete_env("FAKE_DIR")
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(dir)
    end)

    answer = fn command, output -> File.write!(Path.join(dir, command), output) end

    answer.(
      "status--a",
      ~s({"Organization":{"Slug":"acme"},"Machines":[{"state":"started","region":"ewr"}]})
    )

    answer.("apps-list", ~s([]))

    %{answer: answer, calls: fn -> File.read!(Path.join(dir, "calls")) end}
  end

  defp release(answer, vars) do
    answer.("ssh-console", Enum.map_join(vars, "\n", fn {k, v} -> "#{k}=#{v}" end))
  end

  test "refuses an app that does not run with long names, before creating anything",
       %{answer: answer, calls: calls} do
    release(answer, RELEASE_COOKIE: @cookie, RELEASE_DISTRIBUTION: "sname")

    error = assert_raise Mix.Error, fn -> Mix.Tasks.Porthole.Fly.Up.run(["shop"]) end
    assert error.message =~ "does not run with long names"
    refute error.message =~ @cookie
    refute calls.() =~ "apps create"
    refute calls.() =~ "secrets"
  end

  test "refuses an app without IPv6 distribution", %{answer: answer} do
    release(answer, RELEASE_COOKIE: @cookie, RELEASE_DISTRIBUTION: "name")

    error = assert_raise Mix.Error, fn -> Mix.Tasks.Porthole.Fly.Up.run(["shop"]) end
    assert error.message =~ "IPv6"
  end

  test "never deploys over an app that is not a sidecar", %{answer: answer, calls: calls} do
    release(answer,
      RELEASE_COOKIE: @cookie,
      RELEASE_DISTRIBUTION: "name",
      ERL_AFLAGS: "-proto_dist inet6_tcp"
    )

    answer.("apps-list", ~s([{"Name":"shop-porthole","Deployed":true}]))
    answer.("config-show", ~s({"env":{"PORT":"8080"}}))

    error = assert_raise Mix.Error, fn -> Mix.Tasks.Porthole.Fly.Up.run(["shop"]) end
    assert error.message =~ "not a Porthole sidecar"
    refute calls.() =~ "secrets"
    refute calls.() =~ "deploy"
  end

  test "down never destroys an app that is not a sidecar", %{answer: answer, calls: calls} do
    answer.("apps-list", ~s([{"Name":"shop-porthole","Deployed":true}]))
    answer.("config-show", ~s({"env":{"PORT":"8080"}}))

    assert_raise Mix.Error, ~r/refusing/, fn ->
      Mix.Tasks.Porthole.Fly.Down.run(["shop", "--yes"])
    end

    refute calls.() =~ "destroy"
  end

  test "down destroys the sidecar", %{answer: answer, calls: calls} do
    answer.("apps-list", ~s([{"Name":"shop-porthole","Deployed":true}]))
    answer.("config-show", ~s({"env":{"PORTHOLE_PORT":"4040"}}))
    answer.("apps-destroy", "Destroyed app shop-porthole")

    capture_io(fn -> Mix.Tasks.Porthole.Fly.Down.run(["shop", "--yes"]) end)
    assert calls.() =~ "apps destroy shop-porthole --yes"
  end

  test "an unknown app is a clear error" do
    File.rm!(Path.join(System.get_env("FAKE_DIR"), "status--a"))

    assert_raise Mix.Error, ~r/could not find the Fly app nope/, fn ->
      Mix.Tasks.Porthole.Fly.Up.run(["nope"])
    end
  end
end
