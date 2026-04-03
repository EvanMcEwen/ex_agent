# ExAgent

An OTP-native agent framework for Elixir, built on [ReqLLM](https://hex.pm/packages/req_llm). Each agent runs as a supervised `GenServer` with its own conversation history, tool execution loop, and usage tracking.

## Installation

```elixir
def deps do
  [
    {:ex_agent, "~> 0.1.0"}
  ]
end
```

## Architecture

```
ExAgent.Supervisor (one_for_one)
├── ExAgent.Registry          — Named process lookup
├── ExAgent.TaskSupervisor    — Async tasks for LLM calls
└── ExAgent.DynamicSupervisor — Hosts agent GenServer instances
```

LLM calls are dispatched to `ExAgent.TaskSupervisor` tasks and results are sent back as messages, keeping agent processes responsive while waiting for the model.

## Quick Start

```elixir
agent = %ExAgent.Agent{
  name: "assistant",
  model: "anthropic:claude-sonnet-4-20250514",
  system_prompt: "You are a helpful assistant."
}

{:ok, pid} = ExAgent.start(agent)

# Synchronous — blocks until response arrives
{:ok, text} = ExAgent.run_sync(pid, "Hello!")
```

## Async Usage

```elixir
{:ok, ref} = ExAgent.run(pid, "Hello!")

# In a receive block or handle_info callback:
receive do
  {:ex_agent, ^ref, {:ok, text}}      -> IO.puts(text)
  {:ex_agent, ^ref, {:error, reason}} -> IO.inspect(reason)
end

# Or just block:
{:ok, text} = ExAgent.await(ref)
```

## Streaming

```elixir
{:ok, ref} = ExAgent.run_stream(pid, "Tell me a story")

receive do
  {:ex_agent, ^ref, {:chunk, text}}            -> IO.write(text)
  {:ex_agent, ^ref, {:tool, name, args}}       -> IO.inspect({:tool, name, args})
  {:ex_agent, ^ref, {:done, {:ok, text}}}      -> IO.puts("\nDone")
  {:ex_agent, ^ref, {:done, {:error, reason}}} -> IO.inspect(reason)
end
```

## Tool Calling

```elixir
weather_tool = %ReqLLM.Tool{
  name: "get_weather",
  description: "Get current weather for a city",
  parameters: %{"city" => :string},
  function: fn %{"city" => city} -> "Sunny in #{city}" end
}

agent = %ExAgent.Agent{
  model: "anthropic:claude-sonnet-4-20250514",
  tools: [weather_tool],
  max_turns: 10
}

{:ok, pid} = ExAgent.start(agent)
{:ok, text} = ExAgent.run_sync(pid, "What's the weather in Paris?")
```

The agent will loop through tool calls automatically until the model returns a final text response or `max_turns` is reached.

## Named Agents

```elixir
agent = %ExAgent.Agent{
  name: "researcher",
  model: "anthropic:claude-haiku-4-5"
}

{:ok, _pid} = ExAgent.start(agent)

# Look up later from anywhere in the application
pid = ExAgent.whereis("researcher")
{:ok, text} = ExAgent.run_sync(pid, "Summarize recent AI news")
```

## Agent Configuration

| Field | Type | Default | Description |
|---|---|---|---|
| `model` | `String.t()` | required | Provider:model string, e.g. `"anthropic:claude-haiku-4-5"` |
| `name` | `atom \| string \| nil` | `nil` | Registered name for `ExAgent.whereis/1` lookup |
| `system_prompt` | `String.t() \| nil` | `nil` | System instruction prepended to every conversation |
| `tools` | `[ReqLLM.Tool.t()]` | `[]` | Tools available to the agent |
| `max_turns` | `pos_integer()` | `10` | Max tool-call iterations per message |
| `timeout` | `pos_integer()` | `120_000` | Milliseconds before `run_sync` times out |
| `generate_opts` | `keyword()` | `[]` | Extra opts forwarded to `ReqLLM.generate_text/3` |
| `metadata` | `map()` | `%{}` | Arbitrary user data attached to the agent |

## Testing with a Local OpenAI-Compatible Server

These steps use [LM Studio](https://lmstudio.ai/) (or any OpenAI-compatible server) running at `192.168.20.192:1234`.

**1. Set the API key before starting iex**

```bash
OPENAI_API_KEY=local iex -S mix
```

**2. Start a todo store and get tools**

```elixir
{:ok, store} = ExAgent.TodoStore.new(ExAgent.TodoStore.InMemory)
tools = ExAgent.Tools.Todo.tools(store)
```

**3. Build the agent**

```elixir
agent = %ExAgent.Agent{
  model: ReqLLM.model!(%{
    provider: :openai,
    id: "gemma-4-e4b-it",
    base_url: "http://192.168.20.192:1234/v1"
  }),
  tools: tools,
  system_prompt: "You are a helpful task management assistant with access to a todo list.",
  max_turns: 10,
  timeout: 60_000
}
```

**4. Start the agent and run messages**

```elixir
{:ok, pid} = ExAgent.start(agent)

{:ok, response} = ExAgent.run_sync(pid, "Add a task to buy groceries, tagged 'shopping'")
IO.puts(response)

{:ok, response} = ExAgent.run_sync(pid, "What tasks do I have?")
IO.puts(response)
```

## API Reference

| Function | Description |
|---|---|
| `ExAgent.start/1` | Start supervised agent under `DynamicSupervisor` |
| `ExAgent.start_link/1` | Start unsupervised (useful for testing) |
| `ExAgent.run/3` | Send message async, returns `{:ok, ref}` |
| `ExAgent.run_stream/3` | Send message, stream tokens to caller |
| `ExAgent.await/2` | Block for result from `run/3` |
| `ExAgent.run_sync/3` | `run/3` + `await/2` in one call |
| `ExAgent.get_state/1` | Snapshot of agent status and usage |
| `ExAgent.whereis/1` | Look up named agent pid |
| `ExAgent.stop/2` | Stop the agent process |
