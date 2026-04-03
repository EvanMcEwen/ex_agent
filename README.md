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

### Folder Structure

```
lib/ex_agent/
├── memory/
│   ├── memory.ex              — Behaviour + wrapper (ExAgent.Memory)
│   └── backends/
│       └── in_memory.ex       — Default in-process backend
├── tool_provider/
│   ├── tool_provider.ex       — Behaviour + wrapper (ExAgent.ToolProvider)
│   └── backends/
│       └── static.ex          — Default static tool list backend
└── tools/
    └── todo/
        ├── todo.ex            — Tool definitions (ExAgent.Tools.Todo)
        ├── item.ex            — Todo item struct (ExAgent.Tools.Todo.Item)
        ├── store.ex           — Behaviour + wrapper (ExAgent.Tools.Todo.Store)
        └── stores/
            └── in_memory.ex   — ETS-backed in-memory store
```

Each feature area follows the same pattern: a behaviour + wrapper module at the top of its directory, and implementations under a `backends/` or `stores/` subdirectory.

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

Tools are passed as a list of `ReqLLM.Tool.t()` structs. The agent loops through tool calls automatically until the model returns a final text response or `max_turns` is reached.

```elixir
weather_tool = ReqLLM.Tool.new!(
  name: "get_weather",
  description: "Get current weather for a city",
  parameter_schema: %{
    "type" => "object",
    "properties" => %{"city" => %{"type" => "string"}},
    "required" => ["city"]
  },
  callback: fn %{"city" => city} -> {:ok, "Sunny in #{city}"} end
)

agent = %ExAgent.Agent{
  model: "anthropic:claude-sonnet-4-20250514",
  tools: [weather_tool],
  max_turns: 10
}

{:ok, pid} = ExAgent.start(agent)
{:ok, text} = ExAgent.run_sync(pid, "What's the weather in Paris?")
```

### Built-in Todo Tools

ExAgent ships with a ready-made todo tool set. Pass the store backend module to `ExAgent.Tools.Todo.tools/1` — the store process is started and managed automatically:

```elixir
agent = %ExAgent.Agent{
  model: "anthropic:claude-sonnet-4-20250514",
  tools: ExAgent.Tools.Todo.tools(ExAgent.Tools.Todo.Store.InMemory),
  system_prompt: "You are a helpful task management assistant."
}

{:ok, pid} = ExAgent.start(agent)
{:ok, text} = ExAgent.run_sync(pid, "Add 'buy groceries' to my shopping list")
```

The four tools exposed to the model are `todo_create`, `todo_list`, `todo_update`, and `todo_delete`.

To implement a persistent store backend (e.g. backed by a database), implement the `ExAgent.Tools.Todo.Store` behaviour:

```elixir
defmodule MyApp.Todo.Store.Database do
  @behaviour ExAgent.Tools.Todo.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def create(pid, content, tags), do: GenServer.call(pid, {:create, content, tags})
  def list(pid, tag), do: GenServer.call(pid, {:list, tag})
  def update(pid, id, changes), do: GenServer.call(pid, {:update, id, changes})
  def delete(pid, id), do: GenServer.call(pid, {:delete, id})
  # ...
end

tools = ExAgent.Tools.Todo.tools(MyApp.Todo.Store.Database, repo: MyApp.Repo)
```

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

## Pluggable Backends

### Memory

Controls how conversation history is stored and projected into each LLM call. The default `InMemory` backend accumulates all messages in a `ReqLLM.Context.t()`.

```elixir
defmodule MyApp.Memory.Database do
  @behaviour ExAgent.Memory

  def init(opts), do: {:ok, connect(opts)}
  def add_system_prompt(state, content), do: persist_system(state, content)
  def append_user(state, content), do: persist(state, :user, content)
  def append_assistant(state, message), do: persist(state, :assistant, message)
  def append_tool_results(state, calls, results), do: persist_results(state, calls, results)
  def to_context(state), do: load_context(state)
  def message_count(state), do: count(state)
end

agent = %ExAgent.Agent{
  model: "anthropic:claude-sonnet-4-20250514",
  memory_backend: MyApp.Memory.Database,
  memory_opts: [session_id: uuid]
}
```

### Tool Provider

Controls which tools are available to the agent at runtime. The default `Static` backend wraps the `tools:` list on the agent config. A dynamic backend can vary the tool set across turns.

```elixir
defmodule MyApp.Tools.Dynamic do
  @behaviour ExAgent.ToolProvider

  def init(opts), do: {:ok, load_tools(opts)}
  def list_tools(state), do: current_tools(state)
  def execute(state, name, args), do: dispatch(state, name, args)
end

agent = %ExAgent.Agent{
  model: "anthropic:claude-sonnet-4-20250514",
  tool_provider: MyApp.Tools.Dynamic,
  tool_provider_opts: [tenant_id: id]
}
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
| `memory_backend` | `module()` | `ExAgent.Memory.InMemory` | Memory backend module |
| `memory_opts` | `keyword()` | `[]` | Options forwarded to the memory backend |
| `tool_provider` | `module()` | `ExAgent.ToolProvider.Static` | Tool provider backend module |
| `tool_provider_opts` | `keyword()` | `[]` | Options forwarded to the tool provider |

## Testing with a Local OpenAI-Compatible Server

These steps use [LM Studio](https://lmstudio.ai/) (or any OpenAI-compatible server) running at `192.168.20.192:1234`.

**1. Set the API key before starting iex**

```bash
OPENAI_API_KEY=local iex -S mix
```

**2. Build the agent**

```elixir
agent = %ExAgent.Agent{
  model: ReqLLM.model!(%{
    provider: :openai,
    id: "gemma-4-e4b-it",
    base_url: "http://192.168.20.192:1234/v1"
  }),
  tools: ExAgent.Tools.Todo.tools(ExAgent.Tools.Todo.Store.InMemory),
  system_prompt: "You are a helpful task management assistant with access to a todo list.",
  max_turns: 10,
  timeout: 60_000
}
```

**3. Start the agent and run messages**

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
