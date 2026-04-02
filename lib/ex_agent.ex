defmodule ExAgent do
  @moduledoc """
  A pure Elixir agent framework built on ReqLLM.

  Each agent runs as a GenServer process with its own state, conversation
  history, and tool execution capabilities.

  ## Quick Start

      agent = %ExAgent.Agent{
        name: "assistant",
        model: "anthropic:claude-sonnet-4-20250514",
        system_prompt: "You are a helpful assistant."
      }

      {:ok, pid} = ExAgent.start(agent)

      # Async — returns immediately with a ref
      {:ok, ref} = ExAgent.run(pid, "Hello!")

      # Wait for the result
      {:ok, text} = ExAgent.await(ref)

      # Or use run_sync for convenience
      {:ok, text} = ExAgent.run_sync(pid, "Hello!")

  ## Streaming

      {:ok, ref} = ExAgent.run_stream(pid, "Tell me a story")

      # Receive chunks as they arrive:
      #   {:ex_agent, ref, {:chunk, text}}      — content token
      #   {:ex_agent, ref, {:tool, name, args}} — tool being executed
      #   {:ex_agent, ref, {:done, result}}      — final result
  """

  alias ExAgent.{Agent, Server}

  @doc """
  Starts a supervised agent process under the ExAgent DynamicSupervisor.
  """
  @spec start(Agent.t()) :: DynamicSupervisor.on_start_child()
  def start(%Agent{} = agent) do
    DynamicSupervisor.start_child(ExAgent.DynamicSupervisor, {Server, agent})
  end

  @doc """
  Starts an unsupervised agent process. Useful for testing.
  """
  @spec start_link(Agent.t()) :: GenServer.on_start()
  def start_link(%Agent{} = agent) do
    Server.start_link(agent)
  end

  @doc """
  Sends a user message to the agent. Returns `{:ok, ref}` immediately.

  The result will be delivered to the calling process as:

      {:ex_agent, ref, {:ok, text}}
      {:ex_agent, ref, {:error, reason}}

  Use `await/2` to block for the result, or pattern match in a
  `receive` block or `handle_info` callback.
  """
  @spec run(GenServer.server(), String.t(), keyword()) ::
          {:ok, reference()} | {:error, :already_running}
  def run(server, message, opts \\ []) do
    Server.run(server, message, opts)
  end

  @doc """
  Like `run/3` but streams content tokens to the caller as they arrive.

  Returns `{:ok, ref}` immediately. Messages delivered to caller:

      {:ex_agent, ref, {:chunk, text}}       — a content token
      {:ex_agent, ref, {:tool, name, args}}  — a tool is being executed
      {:ex_agent, ref, {:done, {:ok, text}}} — completed with full text
      {:ex_agent, ref, {:done, {:error, reason}}} — failed
  """
  @spec run_stream(GenServer.server(), String.t(), keyword()) ::
          {:ok, reference()} | {:error, :already_running}
  def run_stream(server, message, opts \\ []) do
    Server.run_stream(server, message, opts)
  end

  @doc """
  Blocks until the result for `ref` arrives, or times out.
  Works with `run/3` (non-streaming) only.
  """
  @spec await(reference(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def await(ref, timeout \\ 120_000) do
    receive do
      {:ex_agent, ^ref, result} -> result
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Sends a message and blocks until the final response. Convenience
  wrapper around `run/3` + `await/2`.
  """
  @spec run_sync(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run_sync(server, message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    with {:ok, ref} <- run(server, message, opts) do
      await(ref, timeout)
    end
  end

  @doc """
  Returns a snapshot of the agent's current state.
  """
  @spec get_state(GenServer.server()) :: map()
  def get_state(server) do
    Server.get_state(server)
  end

  @doc """
  Stops the agent process.
  """
  @spec stop(GenServer.server(), term()) :: :ok
  def stop(server, reason \\ :normal) do
    Server.stop(server, reason)
  end

  @doc """
  Looks up a named agent by its registered name. Returns `nil` if not found.
  """
  @spec whereis(term()) :: pid() | nil
  def whereis(name) do
    case Registry.lookup(ExAgent.Registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
