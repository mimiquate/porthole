defmodule Porthole.Tables.Allocators do
  @moduledoc """
  One row per memory allocator of the VM: how much memory it took from the
  operating system (carriers) and how much of it is in use (blocks). The gap
  is fragmentation, which `erlang:memory/0` does not show: it explains a
  node whose OS-level memory (RSS) is well above `system.memory_total`.
  """

  @behaviour Porthole.Table

  @impl true
  def name, do: "allocators"

  @impl true
  def description,
    do:
      "One row per VM memory allocator: bytes taken from the OS (allocated, close to what " <>
        "the OS sees) vs in use (used). allocated well above used is fragmentation; " <>
        "sum(allocated_bytes) above system.memory_total explains an RSS higher than the VM reports."

  @impl true
  def key, do: :allocator

  @impl true
  def deltas, do: [:used_bytes, :allocated_bytes, :unused_bytes]

  @purposes %{
    temp_alloc: "temporary data, freed within a call",
    sl_alloc: "short-lived data",
    std_alloc: "general purpose (most VM structures)",
    ll_alloc: "long-lived data (code, atoms, the VM's own tables)",
    eheap_alloc: "process heaps (Erlang terms)",
    ets_alloc: "ETS tables",
    fix_alloc: "fixed-size structures (processes, ports)",
    literal_alloc: "literals: constants in loaded code",
    binary_alloc: "binaries (large strings and payloads, shared)",
    driver_alloc: "ports and drivers (sockets, files)"
  }

  @impl true
  def columns do
    [
      {:allocator, :text, "Allocator, e.g. eheap_alloc."},
      {:purpose, :text, "What it allocates, e.g. process heaps."},
      {:instances, :integer, "Instances (usually one per scheduler)."},
      {:used_bytes, :integer, "Bytes in blocks in use."},
      {:allocated_bytes, :integer,
       "Bytes in carriers taken from the OS: what the OS sees for this allocator."},
      {:unused_bytes, :integer,
       "allocated_bytes - used_bytes: memory held but not in use (fragmentation, free space)."},
      {:max_allocated_bytes, :integer,
       "Peak allocated_bytes since start (sum of each instance's peak: an upper bound)."},
      {:single_block_bytes, :integer,
       "Of allocated_bytes, carriers holding one large block each (big binaries, heaps)."}
    ]
  end

  @impl true
  def gather(_limits), do: {:allocators, []}

  @impl true
  def shape(%{rows: allocators}) do
    rows =
      for {allocator, instances} <- allocators do
        totals =
          Enum.reduce(instances, %{used: 0, allocated: 0, max: 0, single: 0}, fn sections, acc ->
            Enum.reduce(sections, acc, &add_section/2)
          end)

        %{
          allocator: Atom.to_string(allocator),
          purpose: Map.get(@purposes, allocator),
          instances: length(instances),
          used_bytes: totals.used,
          allocated_bytes: totals.allocated,
          unused_bytes: totals.allocated - totals.used,
          max_allocated_bytes: totals.max,
          single_block_bytes: totals.single
        }
      end

    {rows, false}
  end

  # A section's blocks (bytes in use) and carriers (bytes from the OS). The
  # pool's entries have no peak values.
  defp add_section({kind, props}, acc) when kind in [:mbcs, :sbcs, :mbcs_pool] do
    used = props |> Keyword.get(:blocks, []) |> Enum.map(&block_size/1) |> Enum.sum()

    {allocated, max} =
      case List.keyfind(props, :carriers_size, 0) do
        {:carriers_size, current, _last_max, max} -> {current, max}
        {:carriers_size, current} -> {current, current}
        nil -> {0, 0}
      end

    %{
      acc
      | used: acc.used + used,
        allocated: acc.allocated + allocated,
        max: acc.max + max,
        single: acc.single + if(kind == :sbcs, do: allocated, else: 0)
    }
  end

  defp add_section(_missing, acc), do: acc

  # {type, [{count, ...}, {size, current, ...}]}, per type of block held.
  defp block_size({_type, stats}) when is_list(stats) do
    case List.keyfind(stats, :size, 0) do
      nil -> 0
      size -> elem(size, 1)
    end
  end

  defp block_size(_other), do: 0
end
