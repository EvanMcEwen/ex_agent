defmodule ExAgent.ToolProvider do
  @moduledoc """
  Behaviour and wrapper for pluggable tool backends.

  A tool provider is responsible for two things:
  1. **Definition** — supplying `ReqLLM.Tool.t()` schemas for the LLM to call
  2. **Execution** — handling tool calls dispatched by the agent loop

  ## Implementing a backend

  Implement the `ExAgent.ToolProvider` behaviour and set it on your agent config:

      agent = %ExAgent.Agent{
        model: "anthropic:claude-sonnet-4-20250514",
        tool_provider: MyApp.Tools.Database,
        tool_provider_opts: [repo: MyApp.Repo, tenant_id: id]
      }

  The default backend is `ExAgent.ToolProvider.Static`, which wraps the `tools:`
  list on the agent config.
  """

  @type t :: %__MODULE__{
          backend: module(),
          state: term()
        }

  defstruct [:backend, :state]

  @doc """
  Called once when the agent process starts. Receives `tool_provider_opts` from
  `ExAgent.Agent`. Should return `{:ok, backend_state}` or `{:error, reason}`.
  """
  @callback init(opts :: keyword()) :: {:ok, state :: term()} | {:error, reason :: term()}

  @doc """
  Returns the list of `ReqLLM.Tool.t()` definitions to advertise to the LLM.
  Called before each LLM request so that dynamic backends can return different
  tool sets over time.
  """
  @callback list_tools(state :: term()) :: [ReqLLM.Tool.t()]

  @doc """
  Executes a tool by name with the given args map. Should return
  `{:ok, result}` where `result` is any term that will be serialised and
  returned to the LLM, or `{:error, reason}` on failure.
  """
  @callback execute(state :: term(), name :: String.t(), args :: map()) ::
              {:ok, term()} | {:error, term()}

  # --- Wrapper API ---

  @spec new(module(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(backend, opts) do
    case backend.init(opts) do
      {:ok, backend_state} -> {:ok, %__MODULE__{backend: backend, state: backend_state}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_tools(t()) :: [ReqLLM.Tool.t()]
  def list_tools(%__MODULE__{} = provider) do
    provider.backend.list_tools(provider.state)
  end

  @spec execute(t(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def execute(%__MODULE__{} = provider, name, args) do
    provider.backend.execute(provider.state, name, args)
  end
end
