defmodule Porthole.TraceTest do
  use ExUnit.Case, async: false

  alias Porthole.Error

  @moduletag :capture_log

  setup do
    previous = Application.get_env(:porthole, :policy)
    Application.put_env(:porthole, :policy, tiers: [:observe, :trace])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:porthole, :policy, previous),
        else: Application.delete_env(:porthole, :policy)
    end)
  end

  defmodule Inbox do
    @moduledoc false
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    @impl true
    def init(nil), do: {:ok, nil}
    @impl true
    def handle_call(_request, _from, state), do: {:reply, :ok, state}
    @impl true
    def handle_cast(_request, state), do: {:noreply, state}
    @impl true
    def handle_info(_message, state), do: {:noreply, state}
  end

  defmodule Worker do
    @moduledoc false
    # Crashes with a FunctionClauseError raised in parse/1, soon after it starts.
    use GenServer
    def start_link(ms), do: GenServer.start_link(__MODULE__, ms)
    @impl true
    def init(ms) do
      Process.send_after(self(), :work, ms)
      {:ok, nil}
    end

    @impl true
    def handle_info(:work, state) do
      parse(:unexpected)
      {:noreply, state}
    end

    def parse(%{"amount" => amount}), do: amount

    def busy(n), do: Enum.reduce(1..n, 0, &(&1 + &2))
  end

  # Sends `message` to `to` every `ms`, until the test ends.
  defp sender(to, message, ms) do
    pid =
      spawn(fn ->
        loop = fn loop ->
          send(to, message)
          Process.sleep(ms)
          loop.(loop)
        end

        loop.(loop)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp query(sql, opts), do: Porthole.query(sql, Keyword.put_new(opts, :window_ms, 300))

  describe "messages_to" do
    test "names who sends to a process, by name or by pid, and what kind of message" do
      inbox = start_supervised!({Inbox, :trace_test_inbox})
      by_name = sender(:trace_test_inbox, {:order_event, 1}, 5)
      by_pid = sender(inbox, :sync, 5)

      caster =
        spawn(fn ->
          loop = fn loop ->
            GenServer.cast(:trace_test_inbox, {:refresh, :all})
            GenServer.call(:trace_test_inbox, {:quote, "sku"})
            Process.sleep(5)
            loop.(loop)
          end

          loop.(loop)
        end)

      on_exit(fn -> Process.exit(caster, :kill) end)

      {:ok, result} =
        query("SELECT sender, tag, count(*) FROM trace_messages GROUP BY 1, 2 ORDER BY 2",
          trace: %{"messages_to" => "trace_test_inbox"}
        )

      senders = Map.new(result.rows, fn [sender, tag, _count] -> {tag, sender} end)
      assert senders["order_event"] == Porthole.Remote.pid(by_name)
      assert senders["sync"] == Porthole.Remote.pid(by_pid)
      assert senders["cast:refresh"] == Porthole.Remote.pid(caster)
      assert senders["call:quote"] == Porthole.Remote.pid(caster)
      assert result.notes == []

      # By pid, as processes.pid renders it.
      {:ok, result} =
        query("SELECT count(*) FROM trace_messages WHERE tag = 'sync'",
          trace: [messages_to: Porthole.Remote.pid(inbox)]
        )

      assert [[count]] = result.rows
      assert count > 0
    end

    test "keeps nothing of the message but its tag" do
      start_supervised!({Inbox, :trace_test_secret})
      sender(:trace_test_secret, {:card, "4242 4242 4242 4242"}, 5)
      sender(:trace_test_secret, "a bare string", 5)

      {:ok, result} =
        query("SELECT * FROM trace_messages", trace: %{messages_to: "trace_test_secret"})

      refute inspect(result) =~ "4242"
      refute inspect(result) =~ "a bare string"

      {:ok, result} =
        query("SELECT DISTINCT tag FROM trace_messages",
          trace: %{messages_to: "trace_test_secret"}
        )

      assert Enum.sort(result.rows, :desc) == [["card"], [nil]]
    end

    test "identifies senders on the node, even after they exit" do
      start_supervised!({Inbox, :trace_test_who})
      named = sender(:trace_test_who, :tick, 5)
      Process.register(named, :trace_test_named_sender)

      # A GenServer that sends once and exits right away.
      {:ok, _} =
        Task.start(fn ->
          for _ <- 1..20 do
            {:ok, pid} = GenServer.start(Inbox, nil)
            send(:trace_test_who, :once)
            GenServer.stop(pid)
            Process.sleep(5)
          end
        end)

      {:ok, result} =
        query(
          "SELECT DISTINCT tag, sender_name, sender_initial_call FROM trace_messages ORDER BY 1",
          trace: %{messages_to: "trace_test_who"}
        )

      # A plain spawn starts in :erlang.apply/2 (as processes shows it): the
      # registered name is what identifies it.
      assert ["tick", "trace_test_named_sender", _apply] =
               Enum.find(result.rows, &(hd(&1) == "tick"))

      # The task that sent :once had exited by the time the query ran.
      assert ["once", nil, once_call] = Enum.find(result.rows, &(hd(&1) == "once"))
      assert once_call =~ "Porthole.TraceTest"
    end

    test "says who started a task that sends, and who started an exited one" do
      start_supervised!({Inbox, :trace_test_task_inbox})

      # A named process that keeps starting tasks, as a LiveView preloading.
      owner =
        spawn(fn ->
          Process.register(self(), :trace_test_owner)

          loop = fn loop ->
            # A task that lives a little (a query), like real ones: one that
            # exits the instant it sends is gone before it can be asked.
            Task.async(fn ->
              send(:trace_test_task_inbox, :from_task)
              Process.sleep(20)
            end)
            |> Task.await()

            Process.sleep(5)
            loop.(loop)
          end

          loop.(loop)
        end)

      on_exit(fn -> Process.exit(owner, :kill) end)

      {:ok, result} =
        query("SELECT DISTINCT sender_started_by FROM trace_messages WHERE tag = 'from_task'",
          trace: %{messages_to: "trace_test_task_inbox"}
        )

      assert result.rows == [["trace_test_owner"]]

      {:ok, result} =
        query("SELECT DISTINCT started_by FROM trace_exits",
          trace: %{exits: "trace_test_owner"}
        )

      assert result.rows == [["trace_test_owner"]]
    end

    test "a task whose caller has exited is said to be started by its supervisor" do
      start_supervised!({Task.Supervisor, name: :trace_test_tasks})
      test = self()

      # The caller starts a task under the supervisor, then exits: the task's
      # $callers names a process that is gone.
      spawn(fn ->
        task = Task.Supervisor.async_nolink(:trace_test_tasks, fn -> Process.sleep(200) end)
        send(test, {:started, task.pid})
      end)

      assert_receive {:started, _task_pid}

      {:ok, result} =
        query("SELECT DISTINCT started_by FROM trace_exits",
          trace: %{exits: "trace_test_tasks"},
          window_ms: 400
        )

      assert result.rows == [["trace_test_tasks"]]
    end

    test "stops at the event limit, and says so" do
      start_supervised!({Inbox, :trace_test_flood})
      for _ <- 1..4, do: sender(:trace_test_flood, :tick, 0)

      Application.put_env(:porthole, :policy, tiers: [:observe, :trace], max_trace_events: 500)

      {:ok, result} =
        query("SELECT count(*) FROM trace_messages",
          trace: %{messages_to: "trace_test_flood"},
          window_ms: 5_000
        )

      assert [[count]] = result.rows
      assert count <= 500
      assert result.truncated
      assert [note] = result.notes
      assert note =~ "event limit"
      assert note =~ "max_trace_events"
    end

    test "a process that is not running is reported, not traced" do
      {:ok, result} =
        query("SELECT count(*) FROM trace_messages", trace: %{messages_to: "TraceTest.Nobody"})

      assert result.rows == [[0]]
      assert [note] = result.notes
      assert note =~ "TraceTest.Nobody is not running on this node"
      # Informative, not a cut.
      refute result.truncated
    end
  end

  describe "calls" do
    test "counts calls and running time per process and function" do
      worker =
        spawn(fn ->
          loop = fn loop ->
            Worker.busy(10_000)
            loop.(loop)
          end

          loop.(loop)
        end)

      on_exit(fn -> Process.exit(worker, :kill) end)

      {:ok, result} =
        query("SELECT pid, function, calls, time_us FROM trace_calls",
          trace: %{calls: "Porthole.TraceTest.Worker.busy/1"}
        )

      assert [[pid, "Porthole.TraceTest.Worker.busy/1", calls, time_us]] = result.rows
      assert pid == Porthole.Remote.pid(worker)
      assert calls > 0 and time_us > 0
    end

    test "refuses OTP and Elixir modules, and reports unknown ones" do
      for module <- [":lists", "Enum", ":gen_server"] do
        {:ok, result} = query("SELECT count(*) FROM trace_calls", trace: %{calls: module})
        assert [note] = result.notes
        assert note =~ "part of OTP or Elixir"
      end

      {:ok, result} = query("SELECT count(*) FROM trace_calls", trace: %{calls: "No.Such.Module"})
      assert [note] = result.notes
      assert note =~ "no module No.Such.Module is loaded"

      {:ok, result} =
        query("SELECT count(*) FROM trace_calls",
          trace: %{calls: "Porthole.TraceTest.Worker.nope/1"}
        )

      assert [note] = result.notes
      assert note =~ "no such function"
    end
  end

  describe "exits" do
    test "reports why a supervisor's children exit: the exception class and where" do
      # One child crashes 20 ms after it starts, the other at once: too soon
      # to be asked who it is, so its name comes from how it was spawned.
      children = [
        Supervisor.child_spec({Worker, 20}, id: :worker),
        Supervisor.child_spec({Worker, 0}, id: :instant)
      ]

      start_supervised!(%{
        id: :trace_test_sup,
        start:
          {Supervisor, :start_link,
           [children, [strategy: :one_for_one, max_restarts: 1_000_000, name: :trace_test_sup]]},
        type: :supervisor
      })

      {:ok, who} =
        query("SELECT DISTINCT initial_call FROM trace_exits WHERE reason <> 'normal'",
          trace: %{exits: "trace_test_sup"},
          window_ms: 300
        )

      # Each crashed child had exited (it lived 20 ms), but it is identified.
      assert who.rows == [["Porthole.TraceTest.Worker.init/1"]], inspect(who)

      {:ok, result} =
        query(
          "SELECT reason, location, count(*) FROM trace_exits WHERE reason <> 'normal' GROUP BY 1, 2",
          trace: %{exits: "trace_test_sup"},
          window_ms: 500
        )

      assert match?(
               [["FunctionClauseError", "Porthole.TraceTest.Worker.parse/1", _]],
               result.rows
             ),
             inspect(result)

      [[_reason, _location, count]] = result.rows
      # Restarted children are traced too.
      assert count > 3
      refute inspect(result) =~ "unexpected"
    end
  end

  defmodule Parser do
    @moduledoc false
    def parse(%{"rate" => rate}) when is_number(rate), do: {:ok, rate}
    def parse(%{"rate" => _}), do: {:error, :invalid_rate}
    def parse(map) when is_map(map), do: {:error, :invalid_payload}
    def parse(:boom), do: raise(ArgumentError, "secret detail 4242")
  end

  describe "shapes" do
    setup do
      Application.put_env(:porthole, :policy, tiers: [:observe, :trace], trace_shapes: true)

      payloads = [%{"rate" => 12.5, "card" => "4242 4242"}, %{"rate" => "13.10"}, :boom]

      caller =
        spawn(fn ->
          Process.register(self(), :trace_test_parser_caller)

          loop = fn loop ->
            for payload <- payloads do
              try do
                Parser.parse(payload)
              rescue
                ArgumentError -> :ok
              end
            end

            Process.sleep(5)
            loop.(loop)
          end

          loop.(loop)
        end)

      on_exit(fn -> Process.exit(caller, :kill) end)
      :ok
    end

    test "records each call's argument and result shapes, outcome and duration" do
      {:ok, result} =
        query(
          "SELECT DISTINCT outcome, args, result, name FROM trace_shapes ORDER BY 1, 2",
          trace: %{shapes: "Porthole.TraceTest.Parser.parse/1"}
        )

      assert [
               ["error", ~s|(%{"rate" => binary(5)})|, "{:error, :invalid_rate}", caller],
               ["ok", ~s|(%{"card" => binary(9), "rate" => float})|, "{:ok, float}", caller],
               ["raised", "(:boom)", "ArgumentError", caller]
             ] = result.rows

      assert caller == "trace_test_parser_caller"
      # Values never leave the node: keys and atoms do, nothing else.
      refute inspect(result) =~ "4242"
      refute inspect(result) =~ "13.10"
      refute inspect(result) =~ "secret"

      # A large map: 16 of its keys, without listing them all.
      big = Map.new(1..2_000, &{&1, &1})

      big_caller =
        spawn(fn ->
          loop = fn loop ->
            Parser.parse(big)
            Process.sleep(5)
            loop.(loop)
          end

          loop.(loop)
        end)

      on_exit(fn -> Process.exit(big_caller, :kill) end)

      {:ok, result} =
        query("SELECT args FROM trace_shapes WHERE args LIKE '%1984 more%' LIMIT 1",
          trace: %{shapes: "Porthole.TraceTest.Parser.parse/1"}
        )

      assert [[args]] = result.rows
      assert args =~ "… (1984 more)"

      {:ok, result} =
        query("SELECT count(*) FROM trace_shapes WHERE duration_us IS NULL OR duration_us < 0",
          trace: %{shapes: "Porthole.TraceTest.Parser.parse/1"}
        )

      assert result.rows == [[0]]
    end

    test "huge arguments, often, stop the trace at its memory cap, with a clear error" do
      # Each call event copies its arguments: a few of these exceed the cap.
      huge = Map.new(1..200_000, &{&1, &1})

      huge_caller =
        spawn(fn ->
          loop = fn loop ->
            Parser.parse(huge)
            Process.sleep(5)
            loop.(loop)
          end

          loop.(loop)
        end)

      on_exit(fn -> Process.exit(huge_caller, :kill) end)

      {:ok, result} =
        query("SELECT count(*) FROM trace_shapes",
          trace: %{shapes: "Porthole.TraceTest.Parser.parse/1"}
        )

      assert [%{message: message}] = result.errors
      assert message =~ "held more memory than a trace may use"
      assert length(:trace.session_info(:all)) == 1
    end

    test "shapes are off unless enabled; they need one function, of the application" do
      # Tracing on, shapes not enabled: the default.
      Application.put_env(:porthole, :policy, tiers: [:observe, :trace])

      assert {:error, %Error{reason: :not_allowed, message: message}} =
               query("SELECT * FROM trace_shapes",
                 trace: %{shapes: "Porthole.TraceTest.Parser.parse/1"}
               )

      assert message =~ "shapes are off on this server"
      assert message =~ "trace_shapes: true"

      # Other traces still work.
      assert {:ok, _} =
               query("SELECT count(*) FROM trace_calls",
                 trace: %{calls: "Porthole.TraceTest.Parser"}
               )

      # A token can still turn them off where the server turned them on.
      Application.put_env(:porthole, :policy, tiers: [:observe, :trace], trace_shapes: true)

      assert {:error, %Error{reason: :not_allowed}} =
               query("SELECT * FROM trace_shapes",
                 trace: %{shapes: "Porthole.TraceTest.Parser.parse/1"},
                 policy: Porthole.Policy.new(trace_shapes: false)
               )

      assert {:error, %Error{reason: :bad_request}} =
               query("SELECT * FROM trace_shapes", trace: %{shapes: "Porthole.TraceTest.Parser"})

      {:ok, result} = query("SELECT count(*) FROM trace_shapes", trace: %{shapes: "Enum.map/2"})
      assert [note] = result.notes
      assert note =~ "part of OTP or Elixir"

      {:ok, result} =
        query("SELECT count(*) FROM trace_shapes",
          trace: %{shapes: "Porthole.TraceTest.Parser.nope/1"}
        )

      assert [note] = result.notes
      assert note =~ "no such function"
    end
  end

  describe "validation" do
    test "needs a window, the trace tier and a matching table" do
      assert {:error, %Error{reason: :window_required}} =
               Porthole.query("SELECT * FROM trace_messages", trace: %{messages_to: "x"})

      assert {:error, %Error{reason: :bad_request, message: message}} =
               query("SELECT * FROM trace_messages", [])

      assert message =~ ~s(trace: {"messages_to")

      assert {:error, %Error{reason: :bad_request, message: message}} =
               query("SELECT * FROM trace_calls", trace: %{messages_to: "x"})

      assert message =~ "trace_calls holds the results of a trace"

      assert {:error, %Error{reason: :bad_request, message: message}} =
               query("SELECT * FROM processes", trace: %{messages_to: "x"})

      assert message =~ "query that table"

      assert {:error, %Error{reason: :bad_request, message: message}} =
               query("SELECT * FROM trace_messages",
                 trace: %{messages_to: "x"},
                 window_ms: 20_000
               )

      assert message =~ "at most 10000"

      Application.put_env(:porthole, :policy, [])

      assert {:error, %Error{reason: :not_allowed}} =
               query("SELECT * FROM trace_messages", trace: %{messages_to: "x"})
    end

    test "rejects malformed traces" do
      for trace <- [
            %{},
            %{"messages_to" => "x", "calls" => "y"},
            %{"spy" => "x"},
            %{"messages_to" => 1},
            %{"messages_to" => "a b"},
            %{"calls" => "Mod.fun"},
            "messages_to",
            [1, 2]
          ] do
        assert {:error, %Error{reason: :bad_request}} =
                 query("SELECT * FROM trace_messages", trace: trace),
               inspect(trace)
      end
    end
  end
end
