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

  test "down destroys a sidecar started by up, once its name is typed",
       %{answer: answer, calls: calls} do
    answer.("apps-list", ~s([{"Name":"shop-porthole","Deployed":true}]))
    answer.("config-show", ~s({"env":{"PORTHOLE_PORT":"4040","PORTHOLE_TRIAL":"true"}}))
    answer.("apps-destroy", "Destroyed app shop-porthole")

    # Pressing Enter, or any other answer, cancels.
    send(self(), {:mix_shell_input, :prompt, "\n"})
    capture_io(fn -> Mix.Tasks.Porthole.Fly.Down.run(["shop"]) end)
    refute calls.() =~ "destroy"

    send(self(), {:mix_shell_input, :prompt, "shop-porthole\n"})
    capture_io(fn -> Mix.Tasks.Porthole.Fly.Down.run(["shop"]) end)
    assert calls.() =~ "apps destroy shop-porthole --yes"
  end

  test "neither up nor down touch a sidecar they did not start (a permanent one)",
       %{answer: answer, calls: calls} do
    release(answer,
      RELEASE_COOKIE: @cookie,
      RELEASE_DISTRIBUTION: "name",
      ERL_AFLAGS: "-proto_dist inet6_tcp"
    )

    answer.("apps-list", ~s([{"Name":"shop-porthole","Deployed":true}]))
    answer.("config-show", ~s({"env":{"PORTHOLE_PORT":"4040"}}))

    assert_raise Mix.Error, ~r/not started by mix porthole.fly.up/, fn ->
      Mix.Tasks.Porthole.Fly.Down.run(["shop", "--yes"])
    end

    assert_raise Mix.Error, ~r/not started by this command/, fn ->
      Mix.Tasks.Porthole.Fly.Up.run(["shop"])
    end

    refute calls.() =~ "destroy"
    refute calls.() =~ "secrets"
    refute calls.() =~ "deploy"
  end

  test "deploys the published image by default, or builds from the checkout with --build" do
    alias Mix.Tasks.Porthole.Fly.Up

    default = Up.deploy_args("shop-porthole", "ewr", [], "fly.toml")
    assert ["deploy" | _] = default
    assert Enum.take(default, -2) == ["--image", "ghcr.io/mimiquate/porthole-sidecar:latest"]
    refute "--dockerfile" in default

    assert Enum.take(Up.deploy_args("shop-porthole", "ewr", [image: "mine:1"], "fly.toml"), -2) ==
             ["--image", "mine:1"]

    built = Up.deploy_args("shop-porthole", "ewr", [build: true], "fly.toml")
    assert "--dockerfile" in built
    refute "--image" in built

    assert_raise Mix.Error, ~r/either --image or --build/, fn ->
      Up.deploy_args("shop-porthole", "ewr", [build: true, image: "mine:1"], "fly.toml")
    end
  end

  test "the sidecar's Fly config travels with the code, not the checkout" do
    config =
      Porthole.Fly.with_config(fn path ->
        assert File.exists?(path)
        File.read!(path)
      end)

    assert config == File.read!("sidecar/fly.toml")
  end

  test "an unknown app is a clear error" do
    File.rm!(Path.join(System.get_env("FAKE_DIR"), "status--a"))

    assert_raise Mix.Error, ~r/could not find the Fly app nope/, fn ->
      Mix.Tasks.Porthole.Fly.Up.run(["nope"])
    end
  end
end
