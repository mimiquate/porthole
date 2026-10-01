defmodule Porthole.Gather.Check do
  @moduledoc false
  # Runs right after Porthole.Gather compiles: extracts each of its public
  # functions' compiled code (Erlang abstract format, from the module's debug
  # info), checks the rules in Porthole.Gather's moduledoc, and keeps the code
  # in a companion module (Porthole.Gather.Code) for Porthole.Remote to
  # evaluate on other nodes.
  #
  # This must happen at compile time: releases strip debug info from .beam
  # files by default, so it cannot be read at runtime.

  @allowed_modules [
    :erlang,
    :lists,
    :maps,
    :proplists,
    :application,
    :application_controller,
    :ets,
    :gen_server,
    :inet
  ]
  @allowed_elixir [{Enum, :reduce, 3}]

  def __after_compile__(env, bytecode) do
    {:ok, {module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(bytecode, [:debug_info])

    forms =
      case backend.debug_info(:erlang_v1, module, data, []) do
        {:ok, forms} ->
          forms

        {:error, _reason} ->
          raise CompileError,
            file: env.file,
            line: 0,
            description:
              "#{inspect(module)} must be compiled with debug info (the debug_info compiler " <>
                "option): Porthole reads its compiled code to run it on nodes without Porthole"
      end

    # The module's own functions, not the compiler-generated ones.
    exported =
      for {:attribute, _, :export, exports} <- forms,
          {name, arity} <- exports,
          not String.starts_with?(Atom.to_string(name), "__"),
          name != :module_info,
          do: {name, arity}

    functions =
      for {:function, _anno, name, arity, clauses} <- forms,
          {name, arity} in exported,
          into: %{} do
        check!(env, name, arity, clauses)
        {{name, arity}, {:fun, 1, {:clauses, clauses}}}
      end

    Module.create(
      Module.concat(module, Code),
      quote do
        @moduledoc false
        @functions unquote(Macro.escape(functions))

        @doc false
        # The compiled code of a Porthole.Gather function, as an expression
        # that evaluates to that function.
        def fun_expr(name, arity), do: Map.fetch!(@functions, {name, arity})
      end,
      Macro.Env.location(env)
    )
  end

  @doc false
  # Returns the calls in `code` that break the rules, as strings.
  @spec violations(term(), [module()], [mfa()]) :: [String.t()]
  def violations(code, allowed_modules \\ @allowed_modules, allowed_elixir \\ @allowed_elixir) do
    code
    |> calls()
    |> Enum.reject(fn
      {:remote, module, _fun, _arity} -> module in allowed_modules
      {:remote_mfa, mfa} -> mfa in allowed_elixir
      _other -> false
    end)
    |> Enum.map(fn
      {:remote, module, fun, arity} -> "#{inspect(module)}.#{fun}/#{arity}"
      {:remote_mfa, {module, fun, arity}} -> "#{inspect(module)}.#{fun}/#{arity}"
      {:local, fun, arity} -> "#{fun}/#{arity} (a call to another function of the module)"
      {:dynamic, _} -> "a call with a module or function computed at runtime"
    end)
    |> Enum.uniq()
  end

  defp check!(env, name, arity, clauses) do
    case violations(clauses) do
      [] ->
        :ok

      calls ->
        raise CompileError,
          file: env.file,
          line: 0,
          description:
            "#{inspect(env.module)}.#{name}/#{arity} must only call OTP modules (it runs on nodes " <>
              "without Porthole, possibly with another Elixir version), but calls: " <>
              Enum.join(calls, ", ")
    end
  end

  # Every call in Erlang abstract code: remote calls, local calls, function
  # references and dynamic calls.
  defp calls({:call, _, {:remote, _, {:atom, _, module}, {:atom, _, fun}}, args}) do
    call =
      if elixir_module?(module),
        do: {:remote_mfa, {module, fun, length(args)}},
        else: {:remote, module, fun, length(args)}

    [call | calls(args)]
  end

  defp calls({:call, _, {:remote, _, _module, _fun} = target, args}),
    do: [{:dynamic, target} | calls(args)]

  defp calls({:call, _, {:atom, _, fun}, args}), do: [{:local, fun, length(args)} | calls(args)]

  defp calls({:fun, _, {:function, {:atom, _, module}, {:atom, _, fun}, {:integer, _, arity}}}) do
    if elixir_module?(module),
      do: [{:remote_mfa, {module, fun, arity}}],
      else: [{:remote, module, fun, arity}]
  end

  defp calls({:fun, _, {:function, fun, arity}}) when is_atom(fun), do: [{:local, fun, arity}]
  defp calls(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> calls()
  defp calls(list) when is_list(list), do: Enum.flat_map(list, &calls/1)
  defp calls(_leaf), do: []

  defp elixir_module?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.")
end
