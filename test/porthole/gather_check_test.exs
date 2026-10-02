defmodule Porthole.Gather.CheckTest do
  @moduledoc """
  The build-time check on code that runs on nodes without Porthole: modules
  using it fail to compile when they call anything a node might not have.
  """
  # Synchronous: debug info is a global compiler option, which `mix test` turns
  # off for code compiled during tests; these modules need it on.
  use ExUnit.Case, async: false

  setup do
    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    on_exit(fn -> Code.put_compiler_option(:debug_info, previous) end)
  end

  defp compile(name, body) do
    Code.compile_string("""
    defmodule Porthole.Gather.CheckTest.#{name} do
      @after_compile Porthole.Gather.Check
      #{body}
    end
    """)
  end

  test "compliant code compiles, and its evaluated form behaves like the compiled one" do
    compile("Ok", """
    def sizes(_caller, list) do
      for item <- list, :erlang.is_list(item), do: :erlang.length(item)
    end
    """)

    module = Porthole.Gather.CheckTest.Ok
    expr = Module.concat(module, Code).fun_expr(:sizes, 2)
    {:value, evaluated, _} = :erl_eval.expr(expr, :erl_eval.new_bindings())

    input = [[1, 2], :skip, [3]]
    assert evaluated.(self(), input) == module.sizes(self(), input)
  end

  test "Elixir functions other than Enum.reduce/3 fail the build" do
    error =
      assert_raise CompileError, fn -> compile("NewerElixir", "def f(_c, l), do: Enum.sum(l)") end

    assert error.description =~ "must only call OTP modules"
    assert error.description =~ "Enum.sum/1"
  end

  test "string interpolation fails the build (it goes through String.Chars)" do
    error =
      assert_raise CompileError, fn ->
        compile("Interpolation", ~S|def f(_c, x), do: "x=#{x}"|)
      end

    assert error.description =~ "String.Chars"
  end

  test "calls to other functions of the module fail the build" do
    error =
      assert_raise CompileError, fn ->
        compile("Local", """
        def f(_c, x), do: helper(x)
        def helper(x), do: x
        """)
      end

    assert error.description =~ "helper/1 (a call to another function of the module)"
  end

  test "Porthole.Gather itself passes, and its code is available for evaluation" do
    assert {:fun, _, {:clauses, [_ | _]}} = Porthole.Gather.Code.fun_expr(:processes, 2)
    assert {:fun, _, {:clauses, [_ | _]}} = Porthole.Gather.Code.fun_expr(:with_deadline, 3)
  end

  test "modules compiled without debug info fail the build with a clear message" do
    Code.put_compiler_option(:debug_info, false)

    error = assert_raise CompileError, fn -> compile("NoDebugInfo", "def f(_c), do: :ok") end
    assert error.description =~ "must be compiled with debug info"
  end
end
