defmodule ExAgent.Tools.Todo.Store.InMemory do
  @moduledoc """
  In-memory `Store` backend backed by an ETS table.

  A `GenServer` owns the table for its lifetime — when the server stops, the
  table is automatically destroyed. All reads and writes are serialised through
  the GenServer, which keeps the table `:protected` (only the owner may write).
  The ETS table can be upgraded to `:public` access for lock-free concurrent
  reads if performance ever becomes a concern.

  ## Options

    * `:name` — optional registered name (standard `GenServer` name format)
  """

  use GenServer

  @behaviour ExAgent.Tools.Todo.Store

  alias ExAgent.Tools.Todo.Item

  # --- Public API (Store callbacks) ---

  @impl ExAgent.Tools.Todo.Store
  def start_link(opts \\ []) do
    {gen_opts, _} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl ExAgent.Tools.Todo.Store
  def create(pid, content, tags) do
    GenServer.call(pid, {:create, content, tags})
  end

  @impl ExAgent.Tools.Todo.Store
  def list(pid, tag \\ nil) do
    GenServer.call(pid, {:list, tag})
  end

  @impl ExAgent.Tools.Todo.Store
  def update(pid, id, changes) do
    GenServer.call(pid, {:update, id, changes})
  end

  @impl ExAgent.Tools.Todo.Store
  def delete(pid, id) do
    GenServer.call(pid, {:delete, id})
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(_opts) do
    table = :ets.new(__MODULE__, [:set, :protected])
    {:ok, table}
  end

  @impl GenServer
  def handle_call({:create, content, tags}, _from, table) do
    id = generate_id()

    item = %Item{
      id: id,
      content: content,
      tags: tags,
      done: false,
      inserted_at: DateTime.utc_now()
    }

    :ets.insert(table, {id, item})
    {:reply, {:ok, item}, table}
  end

  def handle_call({:list, tag}, _from, table) do
    items =
      :ets.foldl(fn {_id, item}, acc -> [item | acc] end, [], table)
      |> filter_by_tag(tag)
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    {:reply, {:ok, items}, table}
  end

  def handle_call({:update, id, changes}, _from, table) do
    result =
      case :ets.lookup(table, id) do
        [{^id, item}] ->
          updated = apply_changes(item, changes)
          :ets.insert(table, {id, updated})
          {:ok, updated}

        [] ->
          {:error, :not_found}
      end

    {:reply, result, table}
  end

  def handle_call({:delete, id}, _from, table) do
    result =
      case :ets.lookup(table, id) do
        [{^id, _}] ->
          :ets.delete(table, id)
          :ok

        [] ->
          {:error, :not_found}
      end

    {:reply, result, table}
  end

  # --- Private ---

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp filter_by_tag(items, nil), do: items

  defp filter_by_tag(items, tag) do
    Enum.filter(items, fn item -> tag in item.tags end)
  end

  defp apply_changes(item, changes) do
    changes = Map.new(changes, fn {k, v} -> {to_string(k), v} end)

    item
    |> maybe_put(:content, changes["content"])
    |> maybe_put(:done, changes["done"])
    |> maybe_put(:tags, changes["tags"])
  end

  defp maybe_put(item, _field, nil), do: item
  defp maybe_put(item, field, value), do: Map.put(item, field, value)
end
