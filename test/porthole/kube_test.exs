defmodule Porthole.KubeTest do
  @moduledoc """
  `mix porthole.k8s.up` / `k8s.down` against a fake `kubectl` that answers
  from canned responses and records its calls, and the objects `up` creates.
  These cover the checks that must stop before anything is created or
  deleted; the full flow needs a cluster and was verified on kind.
  """
  use ExUnit.Case, async: false

  alias Porthole.Kube

  @cookie "secret-cookie-value"

  setup do
    dir = Path.join(System.tmp_dir!(), "porthole-kube-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    kubectl = Path.join(dir, "kubectl")

    # Answers `kubectl [--namespace NS] [--context C] <cmd> <arg> [<name>] ...`
    # from $FAKE_DIR/<cmd>-<arg>[-<name>] (with / as _); `apply` saves what it
    # is given.
    File.write!(kubectl, ~S"""
    #!/bin/sh
    echo "$*" >> "$FAKE_DIR/calls"
    while [ "$1" = --namespace ] || [ "$1" = --context ]; do shift 2; done
    case "$1" in
      apply) cat > "$FAKE_DIR/applied"; exit 0 ;;
      auth) cat "$FAKE_DIR/auth" 2>/dev/null || echo yes; exit 0 ;;
    esac
    for key in "$1-$2-$3" "$1-$2" "$1"; do
      answer="$FAKE_DIR/$(printf '%s' "$key" | tr '/' '_')"
      [ -f "$answer" ] && { cat "$answer"; exit 0; }
    done
    echo "unexpected: kubectl $*" >&2
    exit 1
    """)

    File.chmod!(kubectl, 0o755)
    System.put_env(%{"PORTHOLE_KUBECTL" => kubectl, "FAKE_DIR" => dir})
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      System.delete_env("PORTHOLE_KUBECTL")
      System.delete_env("FAKE_DIR")
      Mix.shell(Mix.Shell.IO)
      File.rm_rf!(dir)
    end)

    answer = fn name, output -> File.write!(Path.join(dir, name), output) end
    # The sidecar does not exist yet.
    answer.("get-deployment-shop-porthole", "")
    answer.("get-deployment-shop", JSON.encode!(deployment()))

    %{answer: answer, dir: dir, calls: fn -> File.read!(Path.join(dir, "calls")) end}
  end

  defp deployment(env \\ [%{name: "RELEASE_DISTRIBUTION", value: "name"}]) do
    %{
      metadata: %{name: "shop", namespace: "prod"},
      spec: %{
        selector: %{matchLabels: %{app: "shop"}},
        template: %{spec: %{containers: [%{name: "app", env: env}]}}
      },
      status: %{readyReplicas: 2}
    }
  end

  defp release(answer, vars) do
    answer.("exec-deployment_shop", Enum.map_join(vars, "\n", fn {k, v} -> "#{k}=#{v}" end))
  end

  test "refuses an app without long names, before creating anything", %{
    answer: answer,
    calls: calls
  } do
    release(answer, RELEASE_COOKIE: @cookie, RELEASE_DISTRIBUTION: "sname")

    error = assert_raise Mix.Error, fn -> Mix.Tasks.Porthole.K8s.Up.run(["shop"]) end
    assert error.message =~ "does not run with long names"
    refute error.message =~ @cookie
    refute calls.() =~ "apply"
  end

  test "refuses node names based on hostnames (the sidecar finds pods by IP)", %{
    answer: answer,
    calls: calls
  } do
    release(answer,
      RELEASE_COOKIE: @cookie,
      RELEASE_DISTRIBUTION: "name",
      RELEASE_NODE: "shop@shop-0.shop-headless.prod.svc.cluster.local"
    )

    assert_raise Mix.Error, ~r/does not use the pod's IP/, fn ->
      Mix.Tasks.Porthole.K8s.Up.run(["shop"])
    end

    refute calls.() =~ "apply"
  end

  test "says which permissions are missing", %{answer: answer, calls: calls} do
    answer.("auth", "no\n")

    assert_raise Mix.Error, ~r/you are not allowed to: create deployments.apps/, fn ->
      Mix.Tasks.Porthole.K8s.Up.run(["shop"])
    end

    refute calls.() =~ "exec deployment"
  end

  test "never takes over a Deployment it did not create", %{answer: answer, calls: calls} do
    answer.(
      "get-deployment-shop-porthole",
      JSON.encode!(deployment([%{name: "PORTHOLE_TOKENS", value: "x"}]))
    )

    assert_raise Mix.Error, ~r/not started by this command/, fn ->
      Mix.Tasks.Porthole.K8s.Up.run(["shop"])
    end

    assert_raise Mix.Error, ~r/refusing to delete it/, fn ->
      Mix.Tasks.Porthole.K8s.Down.run(["shop", "--yes"])
    end

    refute calls.() =~ "apply"
    refute calls.() =~ "delete"
  end

  test "down deletes only what up labelled, after the name is typed", %{
    answer: answer,
    calls: calls
  } do
    trial = put_in(deployment(), [:metadata, :labels], %{Kube.label() => "shop-porthole"})
    answer.("get-deployment-shop-porthole", JSON.encode!(trial))
    answer.("delete", "deleted")

    send(self(), {:mix_shell_input, :prompt, "nope\n"})
    Mix.Tasks.Porthole.K8s.Down.run(["shop", "-n", "prod"])
    refute calls.() =~ "delete"

    send(self(), {:mix_shell_input, :prompt, "shop-porthole\n"})
    Mix.Tasks.Porthole.K8s.Down.run(["shop", "-n", "prod"])

    assert calls.() =~
             "--namespace prod delete deployment,service,secret -l #{Kube.label()}=shop-porthole"
  end

  test "with the cookie in a Secret, it is referenced and never read", %{answer: answer} do
    env = [
      %{
        name: "RELEASE_COOKIE",
        valueFrom: %{secretKeyRef: %{name: "shop-secrets", key: "cookie"}}
      }
    ]

    answer.("get-deployment-shop", JSON.encode!(deployment(env)))
    target = Kube.target("shop", [])
    assert target.cookie_ref == {"shop-secrets", "cookie"}

    release = %{cookie: nil, distribution: "name", node: "shop@10.0.0.1", inet6: false, dns: nil}
    manifest = Kube.manifest("shop-porthole", target, release, tokens: "me:abc", image: "img")
    [secret, service, sidecar] = manifest.items

    assert secret.stringData == %{"PORTHOLE_TOKENS" => "me:abc"}
    refute Map.has_key?(secret.stringData, "RELEASE_COOKIE")

    [container] = sidecar.spec.template.spec.containers
    cookie = Enum.find(container.env, &(&1.name == "RELEASE_COOKIE"))
    assert cookie.valueFrom.secretKeyRef == %{name: "shop-secrets", key: "cookie"}

    assert service.spec.selector == %{"app" => "shop"}
    assert service.spec.clusterIP == "None"

    dns = Enum.find(container.env, &(&1.name == "DNS_CLUSTER_QUERY"))
    assert dns.value == "shop-porthole-nodes.prod.svc.cluster.local"

    # Everything up creates carries the label down deletes by.
    for item <- manifest.items, do: assert(item.metadata.labels[Kube.label()] == "shop-porthole")
  end

  test "reading the release leaves the cookie out when it is referenced", %{
    answer: answer,
    calls: calls
  } do
    release(answer, RELEASE_DISTRIBUTION: "name", RELEASE_NODE: "shop@10.0.0.1")
    target = %{name: "shop", container: "app", namespace: "prod"}

    assert %{cookie: nil, node: "shop@10.0.0.1"} = Kube.release(target, [], false)
    assert calls.() =~ "sh -s nocookie"
  end

  test "without a Secret, the cookie goes into the sidecar's own Secret" do
    target = %{
      name: "shop",
      namespace: "prod",
      selector: %{"app" => "shop"},
      container: "app",
      cookie_ref: nil,
      ready: 2
    }

    release = %{
      cookie: @cookie,
      distribution: "name",
      node: "shop@fd00::1",
      inet6: true,
      dns: nil
    }

    [secret, _service, sidecar] =
      Kube.manifest("p", target, release, tokens: "t", image: "i").items

    assert secret.stringData["RELEASE_COOKIE"] == @cookie
    [container] = sidecar.spec.template.spec.containers
    env = Map.new(container.env, &{&1.name, &1[:value]})
    assert env["ERL_AFLAGS"] == "-proto_dist inet6_tcp"
    assert env["PORTHOLE_BIND"] == "::"
  end
end
