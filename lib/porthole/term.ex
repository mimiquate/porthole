defmodule Porthole.Term do
  @moduledoc """
  Bounded text renderings of arbitrary terms.

  Small terms are rendered with `inspect/2`, which respects custom `Inspect`
  implementations (e.g. `@derive {Inspect, except: [:token]}`). Terms whose
  rendering would not fit are summarized as a JSON *shape*: type, size, a few
  keys and a truncated preview. The full term never reaches the output.
  """

  @max_bytes 256

  @doc """
  Renders `term` in at most #{@max_bytes} bytes.

  ## Examples

      iex> Porthole.Term.render({:worker, 1})
      "{:worker, 1}"

      iex> Porthole.Term.render(Map.new(1..1_000, &{&1, &1})) |> JSON.decode!() |> Map.take(["type", "size"])
      %{"type" => "map", "size" => 1000}

  """
  @spec render(term()) :: String.t()
  def render(term) do
    text = inspect(term, limit: 50, printable_limit: @max_bytes)
    if byte_size(text) <= @max_bytes, do: text, else: JSON.encode!(shape(term))
  end

  defp shape(term) do
    base = %{type: type(term), preview: truncate(inspect(term, limit: 10), 80)}

    cond do
      is_map(term) ->
        keys = term |> Map.keys() |> Enum.take(5) |> Enum.map(&truncate(inspect(&1), 20))
        Map.merge(base, %{size: map_size(term), keys: keys})

      is_tuple(term) ->
        Map.put(base, :size, tuple_size(term))

      is_binary(term) ->
        Map.put(base, :bytes, byte_size(term))

      is_list(term) ->
        Map.put(base, :length, bounded_length(term, 0))

      true ->
        base
    end
  end

  defp type(%module{}), do: "struct #{inspect(module)}"
  defp type(term) when is_map(term), do: "map"
  defp type(term) when is_tuple(term), do: "tuple"
  defp type(term) when is_binary(term), do: "binary"
  defp type(term) when is_list(term), do: "list"
  defp type(_term), do: "other"

  # Improper and very long lists are counted without walking them fully.
  defp bounded_length(_list, 10_000), do: "10000+"
  defp bounded_length([_ | tail], n) when is_list(tail), do: bounded_length(tail, n + 1)
  defp bounded_length([_ | _], n), do: n + 1
  defp bounded_length([], n), do: n

  @doc """
  Renders an atom as a plain name: `Elixir.Foo` becomes `"Foo"`, `:foo`
  becomes `"foo"`.
  """
  @spec name(atom()) :: String.t()
  def name(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> rest -> rest
      name -> name
    end
  end

  @doc ~S'Renders `{m, f, a}` as `"Mod.fun/arity"`, anything else as `nil`.'
  @spec mfa(term()) :: String.t() | nil
  def mfa({m, f, a}) when is_atom(m) and is_atom(f) and is_integer(a),
    do: Exception.format_mfa(m, f, a)

  def mfa(_other), do: nil

  @doc "Truncates `text` to `max_bytes`, marking the cut with `…`."
  @spec truncate(String.t(), pos_integer()) :: String.t()
  def truncate(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  def truncate(text, max_bytes) do
    # Never split a UTF-8 codepoint.
    case text |> binary_part(0, max_bytes - 3) |> String.chunk(:valid) do
      [valid | _] -> valid <> "…"
      [] -> "…"
    end
  end
end
