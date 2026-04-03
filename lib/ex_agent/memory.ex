defmodule ExAgent.Memory do
  @moduledoc """
  Behaviour and wrapper for pluggable conversation memory backends.

  A memory backend is responsible for two things:
  1. **Storage** — persisting user messages, assistant responses, and tool results
  2. **Projection** — constructing a `ReqLLM.Context.t()` for the next LLM call

  ## Implementing a backend

  Implement the `ExAgent.Memory` behaviour and set it on your agent config:

      agent = %ExAgent.Agent{
        model: "anthropic:claude-sonnet-4-20250514",
        memory_backend: MyApp.Memory.Database,
        memory_opts: [repo: MyApp.Repo, session_id: uuid]
      }

  The default backend is `ExAgent.Memory.InMemory`.
  """

  @type t :: %__MODULE__{
          backend: module(),
          state: term()
        }

  defstruct [:backend, :state]

  @doc """
  Called once when the agent process starts. Receives `memory_opts` from
  `ExAgent.Agent`. Should return `{:ok, backend_state}` or `{:error, reason}`.
  """
  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, reason :: term()}

  @doc """
  Called during initialization if the agent has a system prompt. Stored
  separately from messages so backends can persist it as metadata if desired.
  Must still be included when building the context.
  """
  @callback add_system_prompt(state :: term(), content :: String.t()) :: term()

  @doc """
  Appends a user message to memory. Receives the raw string content.
  """
  @callback append_user(state :: term(), content :: String.t()) :: term()

  @doc """
  Appends an assistant response to memory. Receives the full
  `ReqLLM.Message.t()`, which may contain tool call metadata.
  """
  @callback append_assistant(state :: term(), message :: term()) :: term()

  @doc """
  Appends tool results to memory after tool execution. Receives both the
  original tool calls and a list of `{id, name, result}` tuples so that
  backends can persist structured data rather than flattened messages.
  """
  @callback append_tool_results(
              state :: term(),
              tool_calls :: [term()],
              results :: [{id :: String.t(), name :: String.t(), result :: term()}]
            ) :: term()

  @doc """
  Builds the full `ReqLLM.Context.t()` to pass to the LLM. This is the
  projection step — a summarizing backend would window or compress old turns
  here, while `InMemory` returns the accumulated context unchanged.
  """
  @callback to_context(state :: term()) :: ReqLLM.Context.t()

  @doc """
  Returns the total number of messages currently stored, used for logging
  and snapshots.
  """
  @callback message_count(state :: term()) :: non_neg_integer()

  # --- Wrapper API ---

  @spec new(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(backend, opts) do
    case backend.init(opts) do
      {:ok, backend_state} -> {:ok, %__MODULE__{backend: backend, state: backend_state}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec add_system_prompt(t(), String.t()) :: t()
  def add_system_prompt(%__MODULE__{} = mem, content) do
    %{mem | state: mem.backend.add_system_prompt(mem.state, content)}
  end

  @spec append_user(t(), String.t()) :: t()
  def append_user(%__MODULE__{} = mem, content) do
    %{mem | state: mem.backend.append_user(mem.state, content)}
  end

  @spec append_assistant(t(), term()) :: t()
  def append_assistant(%__MODULE__{} = mem, message) do
    %{mem | state: mem.backend.append_assistant(mem.state, message)}
  end

  @spec append_tool_results(t(), [term()], [{String.t(), String.t(), term()}]) :: t()
  def append_tool_results(%__MODULE__{} = mem, tool_calls, results) do
    %{mem | state: mem.backend.append_tool_results(mem.state, tool_calls, results)}
  end

  @spec to_context(t()) :: ReqLLM.Context.t()
  def to_context(%__MODULE__{} = mem) do
    mem.backend.to_context(mem.state)
  end

  @spec message_count(t()) :: non_neg_integer()
  def message_count(%__MODULE__{} = mem) do
    mem.backend.message_count(mem.state)
  end
end
