defmodule ExAgent.Server do
  @moduledoc false

  use GenServer

  require Logger

  alias ExAgent.{Agent, Memory, State, ToolExecutor, ToolProvider}
  alias ReqLLM.{Response, ToolCall}

  # --- Client API ---

  def start_link(%Agent{} = agent) do
    opts = if agent.name, do: [name: via(agent.name)], else: []
    GenServer.start_link(__MODULE__, agent, opts)
  end

  def run(server, user_message, opts \\ []) do
    GenServer.call(server, {:run, user_message, opts})
  end

  def run_stream(server, user_message, opts \\ []) do
    GenServer.call(server, {:run_stream, user_message, opts})
  end

  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  def stop(server, reason \\ :normal) do
    GenServer.stop(server, reason)
  end

  # --- Server Callbacks ---

  @impl true
  def init(%Agent{} = agent) do
    {:ok, State.new(agent)}
  end

  @impl true
  def handle_call({run_type, _msg, _opts}, _from, %State{status: :running} = state)
      when run_type in [:run, :run_stream] do
    {:reply, {:error, :already_running}, state}
  end

  def handle_call({run_type, user_message, opts}, {caller_pid, _}, state)
      when run_type in [:run, :run_stream] do
    ref = make_ref()
    memory = Memory.append_user(state.memory, user_message)
    timeout = Keyword.get(opts, :timeout, state.agent.timeout)
    timer_ref = Process.send_after(self(), {:llm_timeout, ref}, timeout)

    state = %{
      state
      | memory: memory,
        status: :running,
        error: nil,
        caller: {caller_pid, ref},
        timer_ref: timer_ref,
        stream?: run_type == :run_stream
    }

    {:reply, {:ok, ref}, spawn_llm_call(state)}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, State.snapshot(state), state}
  end

  @impl true
  def handle_info({task_ref, {:ok, response}}, %State{task_ref: task_ref} = state) do
    Process.demonitor(task_ref, [:flush])

    state = %{
      state
      | turns: state.turns + 1,
        usage: merge_usage(state.usage, response.usage),
        memory: Memory.append_assistant(state.memory, response.message)
    }

    tool_calls = Response.tool_calls(response)

    if tool_calls == [] do
      text = Response.text(response)
      complete(state, {:ok, text})
    else
      notify_tool_calls(state, tool_calls)

      memory =
        ToolExecutor.execute_tool_calls(tool_calls, state.tool_provider, state.memory)

      state = %{state | memory: memory}

      if state.turns >= state.agent.max_turns do
        complete(state, {:error, :max_turns_exceeded}, :max_turns_exceeded)
      else
        {:noreply, spawn_llm_call(state)}
      end
    end
  end

  def handle_info({task_ref, {:error, reason}}, %State{task_ref: task_ref} = state) do
    Process.demonitor(task_ref, [:flush])
    complete(state, {:error, reason}, :error)
  end

  def handle_info(
        {:DOWN, task_ref, :process, _pid, reason},
        %State{task_ref: task_ref} = state
      ) do
    complete(state, {:error, {:task_crashed, reason}}, :error)
  end

  def handle_info({:llm_timeout, ref}, state) do
    case state.caller do
      {_pid, ^ref} ->
        if state.task_ref do
          Task.Supervisor.terminate_child(ExAgent.TaskSupervisor, state.task_ref)
        end

        complete(state, {:error, :timeout}, :error)

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  defp spawn_llm_call(%State{stream?: true} = state) do
    {model, context, generate_opts} = llm_params(state)
    {caller_pid, caller_ref} = state.caller

    Logger.debug("[ExAgent] llm_call model=#{inspect(model)} stream=true turn=#{state.turns + 1} messages=#{length(ReqLLM.Context.to_list(context))}")

    %Task{ref: task_ref} =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        case ReqLLM.stream_text(model, context, generate_opts) do
          {:ok, stream_response} ->
            {:ok, response} =
              ReqLLM.StreamResponse.process_stream(stream_response,
                on_result: fn text ->
                  send(caller_pid, {:ex_agent, caller_ref, {:chunk, text}})
                end
              )

            Logger.debug("[ExAgent] llm_response stream=true tool_calls=#{length(Response.tool_calls(response))} usage=#{inspect(response.usage)}")
            {:ok, response}

          {:error, reason} ->
            Logger.debug("[ExAgent] llm_error stream=true reason=#{inspect(reason)}")
            {:error, reason}
        end
      end)

    %{state | task_ref: task_ref}
  end

  defp spawn_llm_call(state) do
    {model, context, generate_opts} = llm_params(state)

    Logger.debug("[ExAgent] llm_call model=#{inspect(model)} stream=false turn=#{state.turns + 1} messages=#{length(ReqLLM.Context.to_list(context))}")

    %Task{ref: task_ref} =
      Task.Supervisor.async_nolink(ExAgent.TaskSupervisor, fn ->
        case ReqLLM.generate_text(model, context, generate_opts) do
          {:ok, response} ->
            Logger.debug("[ExAgent] llm_response stream=false tool_calls=#{length(Response.tool_calls(response))} usage=#{inspect(response.usage)}")
            {:ok, response}

          {:error, reason} ->
            Logger.debug("[ExAgent] llm_error stream=false reason=#{inspect(reason)}")
            {:error, reason}
        end
      end)

    %{state | task_ref: task_ref}
  end

  defp llm_params(state) do
    tools = ToolProvider.list_tools(state.tool_provider)
    generate_opts = Keyword.merge(state.agent.generate_opts, tools: tools)
    context = Memory.to_context(state.memory)
    {state.agent.model, context, generate_opts}
  end

  defp notify_tool_calls(%State{stream?: true, caller: {caller_pid, ref}}, tool_calls) do
    for call <- tool_calls do
      send(caller_pid, {:ex_agent, ref, {:tool, ToolCall.name(call), ToolCall.args_map(call)}})
    end
  end

  defp notify_tool_calls(_state, _tool_calls), do: :ok

  defp complete(state, result, status \\ :completed)

  defp complete(%State{stream?: true} = state, result, status) do
    cancel_timer(state.timer_ref)
    notify_caller(state.caller, {:done, result})

    {:noreply,
     %{
       state
       | status: status,
         caller: nil,
         task_ref: nil,
         timer_ref: nil,
         stream?: false,
         error: if(status != :completed, do: elem(result, 1))
     }}
  end

  defp complete(state, result, status) do
    cancel_timer(state.timer_ref)
    notify_caller(state.caller, result)

    {:noreply,
     %{
       state
       | status: status,
         caller: nil,
         task_ref: nil,
         timer_ref: nil,
         error: if(status != :completed, do: elem(result, 1))
     }}
  end

  defp notify_caller({caller_pid, ref}, result) do
    send(caller_pid, {:ex_agent, ref, result})
  end

  defp notify_caller(nil, _result), do: :ok

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)

    receive do
      {:llm_timeout, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp via(name), do: {:via, Registry, {ExAgent.Registry, name}}

  defp merge_usage(acc, nil), do: acc

  defp merge_usage(acc, new) do
    %{
      input_tokens: acc.input_tokens + (Map.get(new, :input_tokens, 0) || 0),
      output_tokens: acc.output_tokens + (Map.get(new, :output_tokens, 0) || 0),
      total_tokens: acc.total_tokens + (Map.get(new, :total_tokens, 0) || 0),
      reasoning_tokens: acc.reasoning_tokens + (Map.get(new, :reasoning_tokens, 0) || 0),
      total_cost: acc.total_cost + (get_in(new, [:cost, :total]) || 0)
    }
  end
end
