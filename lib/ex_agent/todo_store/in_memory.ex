defmodule ExAgent.TodoStore.InMemory do
  @moduledoc """
  In-memory `TodoStore` backend backed by an ETS table.

  A `GenServer` owns the table for its lifetime — when the server stops, the
  table is automatically destroyed. All reads and writes are serialised through
  the GenServer, which keeps the table `:protected` (only the owner may write).
  The ETS table can be upgraded to `:public` access for lock-free concurrent
  reads if performance ever becomes a concern.

  ## Options

    * `:name` — optional registered name (standard `GenServer` name format)
  """

  use GenServer

  @behaviour ExAgent.TodoStore

  alias ExAgent.Todo

  # --- Public API (TodoStore callbacks) ---

  @impl ExAgent.TodoStore
  def start_link(opts \\ []) do
    {gen_opts, _} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl ExAgent.TodoStore
  def create(pid, content, tags) do
    GenServer.call(pid, {:create, content, tags})
  end

  @impl ExAgent.TodoStore
  def list(pid, tag \\ nil) do
    GenServer.call(pid, {:list, tag})
  end

  @impl ExAgent.TodoStore
  def update(pid, id, changes) do
    GenServer.call(pid, {:update, id, changes})
  end

  @impl ExAgent.TodoStore
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

    todo = %Todo{
      id: id,
      content: content,
      tags: tags,
      done: false,
      inserted_at: DateTime.utc_now()
    }

    :ets.insert(table, {id, todo})
    {:reply, {:ok, todo}, table}
  end

  def handle_call({:list, tag}, _from, table) do
    todos =
      :ets.foldl(fn {_id, todo}, acc -> [todo | acc] end, [], table)
      |> filter_by_tag(tag)
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})

    {:reply, {:ok, todos}, table}
  end

  def handle_call({:update, id, changes}, _from, table) do
    result =
      case :ets.lookup(table, id) do
        [{^id, todo}] ->
          updated = apply_changes(todo, changes)
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

  defp filter_by_tag(todos, nil), do: todos

  defp filter_by_tag(todos, tag) do
    Enum.filter(todos, fn todo -> tag in todo.tags end)
  end

  defp apply_changes(todo, changes) do
    changes = Map.new(changes, fn {k, v} -> {to_string(k), v} end)

    todo
    |> maybe_put(:content, changes["content"])
    |> maybe_put(:done, changes["done"])
    |> maybe_put(:tags, changes["tags"])
  end

  defp maybe_put(todo, _field, nil), do: todo
  defp maybe_put(todo, field, value), do: Map.put(todo, field, value)
end
