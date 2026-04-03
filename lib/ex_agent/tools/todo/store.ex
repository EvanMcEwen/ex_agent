defmodule ExAgent.Tools.Todo.Store do
  @moduledoc """
  Behaviour and wrapper for pluggable todo storage backends.

  A todo store backend is responsible for persisting and querying todo items.
  Multiple "lists" are modelled as tags — a todo can belong to multiple lists
  by having multiple tags, and callers filter by tag when listing.

  ## Implementing a backend

  Implement the `ExAgent.Tools.Todo.Store` behaviour. Unlike the functional
  `Memory` and `ToolProvider` backends, a todo store is **process-based**:
  `start_link/1` must start a process whose `pid` is threaded through every
  subsequent call. This allows mutations from tool callbacks to be reflected
  immediately without modifying the agent's internal state.

      defmodule MyApp.Todo.Store.Database do
        @behaviour ExAgent.Tools.Todo.Store

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        # ...
      end

  Then start it with `ExAgent.Tools.Todo.Store.new/2` and pass the resulting
  struct to `ExAgent.Tools.Todo.tools/1`:

      {:ok, store} = ExAgent.Tools.Todo.Store.new(MyApp.Todo.Store.Database, repo: MyApp.Repo)
      tools = ExAgent.Tools.Todo.tools(store)

  The default backend is `ExAgent.Tools.Todo.Store.InMemory`.
  """

  @type t :: %__MODULE__{
          backend: module(),
          pid: pid()
        }

  defstruct [:backend, :pid]

  @doc "Starts the backend process. Must return `{:ok, pid}` or `{:error, reason}`."
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}

  @doc "Creates a new todo with the given content and tags. Returns `{:ok, todo}`."
  @callback create(store :: pid(), content :: String.t(), tags :: [String.t()]) ::
              {:ok, ExAgent.Tools.Todo.Item.t()} | {:error, term()}

  @doc """
  Lists todos. When `tag` is `nil`, returns all todos; otherwise returns only
  todos that include `tag` in their tags list.
  """
  @callback list(store :: pid(), tag :: String.t() | nil) ::
              {:ok, [ExAgent.Tools.Todo.Item.t()]}

  @doc """
  Updates a todo by id. `changes` is a map with any of the keys
  `"content"`, `"tags"`, or `"done"`. Returns `{:ok, updated_todo}` or
  `{:error, :not_found}`.
  """
  @callback update(store :: pid(), id :: String.t(), changes :: map()) ::
              {:ok, ExAgent.Tools.Todo.Item.t()} | {:error, :not_found}

  @doc "Deletes a todo by id. Returns `:ok` or `{:error, :not_found}`."
  @callback delete(store :: pid(), id :: String.t()) :: :ok | {:error, :not_found}

  # --- Wrapper API ---

  @spec new(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(backend, opts \\ []) do
    case backend.start_link(opts) do
      {:ok, pid} -> {:ok, %__MODULE__{backend: backend, pid: pid}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create(t(), String.t(), [String.t()]) ::
          {:ok, ExAgent.Tools.Todo.Item.t()} | {:error, term()}
  def create(%__MODULE__{backend: b, pid: p}, content, tags \\ []) do
    b.create(p, content, tags)
  end

  @spec list(t(), String.t() | nil) :: {:ok, [ExAgent.Tools.Todo.Item.t()]}
  def list(%__MODULE__{backend: b, pid: p}, tag \\ nil) do
    b.list(p, tag)
  end

  @spec update(t(), String.t(), map()) ::
          {:ok, ExAgent.Tools.Todo.Item.t()} | {:error, :not_found}
  def update(%__MODULE__{backend: b, pid: p}, id, changes) do
    b.update(p, id, changes)
  end

  @spec delete(t(), String.t()) :: :ok | {:error, :not_found}
  def delete(%__MODULE__{backend: b, pid: p}, id) do
    b.delete(p, id)
  end
end
