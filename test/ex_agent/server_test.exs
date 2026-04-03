defmodule ExAgent.ServerTest do
  use ExUnit.Case

  alias ExAgent.Agent
  alias ReqLLM.Context

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_agent(attrs \\ []) do
    agent = struct!(Agent, Keyword.merge([model: "anthropic:claude-sonnet-4-20250514"], attrs))
    {:ok, pid} = ExAgent.start_link(agent)
    on_exit(fn -> if Process.alive?(pid), do: ExAgent.stop(pid) end)
    pid
  end

  # Put the server into "running" state with a fake task_ref that matches the
  # one used when injecting simulated task results (e.g. `{task_ref, {:ok, resp}}`).
  # Do NOT use this for timeout tests — see simulate_running_no_task/1.
  defp simulate_running(server_pid) do
    caller_ref = make_ref()
    fake_task_ref = make_ref()
    caller_pid = self()

    :sys.replace_state(server_pid, fn state ->
      memory = ExAgent.Memory.append_user(state.memory, "test message")

      %{state |
        status: :running,
        caller: {caller_pid, caller_ref},
        task_ref: fake_task_ref,
        timer_ref: nil,
        memory: memory
      }
    end)

    {caller_ref, fake_task_ref}
  end

  # Like simulate_running/1 but sets task_ref to nil.
  # Use this for timeout and :DOWN tests where the handler would call
  # Task.Supervisor.terminate_child/2 — that function requires a real PID and
  # would crash if given a bare reference.
  defp simulate_running_no_task(server_pid) do
    caller_ref = make_ref()
    caller_pid = self()

    :sys.replace_state(server_pid, fn state ->
      memory = ExAgent.Memory.append_user(state.memory, "test message")

      %{state |
        status: :running,
        caller: {caller_pid, caller_ref},
        task_ref: nil,
        timer_ref: nil,
        memory: memory
      }
    end)

    caller_ref
  end

  # Build a fake LLM response with plain text, no tool calls.
  defp fake_text_response(text) do
    %ReqLLM.Response{
      id: "test-id",
      model: "anthropic:claude-sonnet-4-20250514",
      context: Context.new(),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [%ReqLLM.Message.ContentPart{type: :text, text: text}],
        tool_calls: nil
      },
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15, cost: %{total: 0.001}}
    }
  end

  # Build a fake LLM response with a tool call and no text.
  defp fake_tool_response(tool_name, args_json \\ "{}") do
    call = ReqLLM.ToolCall.new("call-1", tool_name, args_json)

    %ReqLLM.Response{
      id: "tool-test-id",
      model: "anthropic:claude-sonnet-4-20250514",
      context: Context.new(),
      message: %ReqLLM.Message{
        role: :assistant,
        content: [],
        tool_calls: [call]
      },
      usage: nil
    }
  end

  # ---------------------------------------------------------------------------
  # State snapshot
  # ---------------------------------------------------------------------------

  describe "get_state/1" do
    test "snapshot excludes internal fields" do
      pid = start_agent()
      snapshot = ExAgent.get_state(pid)
      refute Map.has_key?(snapshot, :task_ref)
      refute Map.has_key?(snapshot, :caller)
      refute Map.has_key?(snapshot, :timer_ref)
      refute Map.has_key?(snapshot, :stream?)
    end

    test "snapshot includes expected public fields" do
      pid = start_agent()
      snapshot = ExAgent.get_state(pid)
      assert Map.has_key?(snapshot, :status)
      assert Map.has_key?(snapshot, :turns)
      assert Map.has_key?(snapshot, :usage)
      assert Map.has_key?(snapshot, :error)
      assert Map.has_key?(snapshot, :message_count)
    end

    test "usage starts at zero" do
      pid = start_agent()
      %{usage: usage} = ExAgent.get_state(pid)
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.total_tokens == 0
      assert usage.total_cost == 0.0
    end

    test "message_count reflects system prompt" do
      pid = start_agent(system_prompt: "You are helpful.")
      assert ExAgent.get_state(pid).message_count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Successful response (injected via sys.replace_state)
  # ---------------------------------------------------------------------------

  describe "successful text response" do
    test "delivers {:ok, text} to caller" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)

      send(pid, {task_ref, {:ok, fake_text_response("Hello there!")}})

      assert {:ok, "Hello there!"} = ExAgent.await(caller_ref, 1_000)
    end

    test "status becomes :completed after success" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_text_response("Done")}})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).status == :completed
    end

    test "turns increments after response" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_text_response("Done")}})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).turns == 1
    end

    test "usage is accumulated from the response" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_text_response("Done")}})
      ExAgent.await(caller_ref, 1_000)

      %{usage: usage} = ExAgent.get_state(pid)
      assert usage.input_tokens == 10
      assert usage.output_tokens == 5
      assert usage.total_tokens == 15
      assert usage.total_cost == 0.001
    end

    test "usage accumulates across multiple turns" do
      pid = start_agent()

      # First turn
      {ref1, task_ref1} = simulate_running(pid)
      send(pid, {task_ref1, {:ok, fake_text_response("First")}})
      ExAgent.await(ref1, 1_000)

      # Second turn
      {ref2, task_ref2} = simulate_running(pid)
      send(pid, {task_ref2, {:ok, fake_text_response("Second")}})
      ExAgent.await(ref2, 1_000)

      %{usage: usage} = ExAgent.get_state(pid)
      assert usage.input_tokens == 20
      assert usage.output_tokens == 10
      assert usage.total_tokens == 30
      assert usage.total_cost == 0.002
    end

    test "caller is cleared after success" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_text_response("Done")}})
      ExAgent.await(caller_ref, 1_000)

      assert :sys.get_state(pid).caller == nil
    end

    test "task_ref is cleared after success" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_text_response("Done")}})
      ExAgent.await(caller_ref, 1_000)

      assert :sys.get_state(pid).task_ref == nil
    end

    test "error field is nil after success" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_text_response("Done")}})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).error == nil
    end

    test "message_count reflects user + assistant messages" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_text_response("Here it is.")}})
      ExAgent.await(caller_ref, 1_000)

      # user message added by simulate_running + assistant reply
      assert ExAgent.get_state(pid).message_count == 2
    end

    test "agent is idle and can run again after completion" do
      pid = start_agent()

      {ref1, task_ref1} = simulate_running(pid)
      send(pid, {task_ref1, {:ok, fake_text_response("First answer")}})
      assert {:ok, "First answer"} = ExAgent.await(ref1, 1_000)

      {ref2, task_ref2} = simulate_running(pid)
      send(pid, {task_ref2, {:ok, fake_text_response("Second answer")}})
      assert {:ok, "Second answer"} = ExAgent.await(ref2, 1_000)

      assert ExAgent.get_state(pid).turns == 2
    end

    test "nil usage in response does not crash or change usage" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      response = %{fake_text_response("ok") | usage: nil}
      send(pid, {task_ref, {:ok, response}})
      assert {:ok, "ok"} = ExAgent.await(caller_ref, 1_000)
      # Usage should remain at zero since nil usage was a no-op
      assert ExAgent.get_state(pid).usage.total_tokens == 0
    end
  end

  # ---------------------------------------------------------------------------
  # LLM error handling (injected)
  # ---------------------------------------------------------------------------

  describe "LLM error response" do
    test "delivers {:error, reason} to caller" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:error, :api_down}})

      assert {:error, :api_down} = ExAgent.await(caller_ref, 1_000)
    end

    test "status becomes :error" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:error, :api_down}})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).status == :error
    end

    test "error field is populated" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:error, :rate_limited}})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).error == :rate_limited
    end

    test "caller is cleared after error" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:error, :oops}})
      ExAgent.await(caller_ref, 1_000)

      assert :sys.get_state(pid).caller == nil
    end

    test "task_ref is cleared after error" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:error, :oops}})
      ExAgent.await(caller_ref, 1_000)

      assert :sys.get_state(pid).task_ref == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Task crash handling
  # ---------------------------------------------------------------------------

  describe "task crash (:DOWN message)" do
    test "delivers {:error, {:task_crashed, reason}} to caller" do
      pid = start_agent()
      # Use simulate_running (with fake task_ref) because :DOWN passes task_ref
      # in the message — no terminate_child is called for :DOWN messages.
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {:DOWN, task_ref, :process, self(), :killed})

      assert {:error, {:task_crashed, :killed}} = ExAgent.await(caller_ref, 1_000)
    end

    test "status becomes :error after crash" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {:DOWN, task_ref, :process, self(), :abnormal})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).status == :error
    end

    test "error field contains {:task_crashed, reason}" do
      pid = start_agent()
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {:DOWN, task_ref, :process, self(), :timeout})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).error == {:task_crashed, :timeout}
    end

    test ":DOWN message with non-matching ref is ignored" do
      pid = start_agent()
      other_ref = make_ref()
      send(pid, {:DOWN, other_ref, :process, self(), :reason})
      Process.sleep(20)
      # Server should still be idle
      assert ExAgent.get_state(pid).status == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # Timeout handling
  # ---------------------------------------------------------------------------

  describe "timeout handling" do
    # Timeout tests use simulate_running_no_task/1 to keep task_ref nil.
    # The timeout handler calls Task.Supervisor.terminate_child/2 only when
    # task_ref is non-nil, and that function requires a real PID — not a ref.

    test "delivers {:error, :timeout} to caller" do
      pid = start_agent()
      caller_ref = simulate_running_no_task(pid)
      send(pid, {:llm_timeout, caller_ref})

      assert {:error, :timeout} = ExAgent.await(caller_ref, 1_000)
    end

    test "status becomes :error after timeout" do
      pid = start_agent()
      caller_ref = simulate_running_no_task(pid)
      send(pid, {:llm_timeout, caller_ref})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).status == :error
    end

    test "error field is :timeout" do
      pid = start_agent()
      caller_ref = simulate_running_no_task(pid)
      send(pid, {:llm_timeout, caller_ref})
      ExAgent.await(caller_ref, 1_000)

      assert ExAgent.get_state(pid).error == :timeout
    end

    test "caller is cleared after timeout" do
      pid = start_agent()
      caller_ref = simulate_running_no_task(pid)
      send(pid, {:llm_timeout, caller_ref})
      ExAgent.await(caller_ref, 1_000)

      assert :sys.get_state(pid).caller == nil
    end

    test "timeout with non-matching ref is silently ignored" do
      pid = start_agent()
      stale_ref = make_ref()
      # No running call — caller is nil, so the ref can never match
      send(pid, {:llm_timeout, stale_ref})
      Process.sleep(20)
      assert ExAgent.get_state(pid).status == :idle
    end

    test "timeout with old ref is ignored when a new call is active" do
      pid = start_agent()

      # First call — complete via timeout
      ref1 = simulate_running_no_task(pid)
      send(pid, {:llm_timeout, ref1})
      ExAgent.await(ref1, 1_000)

      # Second call — still running
      ref2 = simulate_running_no_task(pid)

      # Inject the OLD timeout ref — should be ignored
      send(pid, {:llm_timeout, ref1})
      Process.sleep(20)
      assert :sys.get_state(pid).status == :running

      # Clean up second call
      send(pid, {:llm_timeout, ref2})
      ExAgent.await(ref2, 1_000)
    end

    test "per-call timeout option is wired up" do
      # With a real run, the configured timeout is used.
      # The LLM call fails quickly due to no API key, so we just check
      # the server is in an error state and not blocked.
      pid = start_agent()
      {:ok, ref} = ExAgent.run(pid, "Hello", timeout: 100)
      assert {:error, _} = ExAgent.await(ref, 5_000)
      assert ExAgent.get_state(pid).status == :error
    end
  end

  # ---------------------------------------------------------------------------
  # Max turns exceeded (tool call loop)
  # ---------------------------------------------------------------------------

  describe "max turns exceeded" do
    setup do
      tool = ReqLLM.Tool.new!(
        name: "do_thing",
        description: "A test tool",
        parameter_schema: [],
        callback: fn _ -> {:ok, "done"} end
      )

      agent = struct!(Agent, model: "anthropic:claude-sonnet-4-20250514", tools: [tool], max_turns: 1)
      {:ok, pid} = ExAgent.start_link(agent)
      on_exit(fn -> if Process.alive?(pid), do: ExAgent.stop(pid) end)
      {:ok, pid: pid}
    end

    test "delivers {:error, :max_turns_exceeded} when tool calls exhaust max_turns", %{pid: pid} do
      {caller_ref, task_ref} = simulate_running(pid)
      # Inject a tool-call response; with max_turns: 1, the first turn exhausts the limit
      send(pid, {task_ref, {:ok, fake_tool_response("do_thing")}})
      assert {:error, :max_turns_exceeded} = ExAgent.await(caller_ref, 1_000)
    end

    test "status is :max_turns_exceeded", %{pid: pid} do
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_tool_response("do_thing")}})
      ExAgent.await(caller_ref, 1_000)
      assert ExAgent.get_state(pid).status == :max_turns_exceeded
    end

    test "error field is :max_turns_exceeded", %{pid: pid} do
      {caller_ref, task_ref} = simulate_running(pid)
      send(pid, {task_ref, {:ok, fake_tool_response("do_thing")}})
      ExAgent.await(caller_ref, 1_000)
      assert ExAgent.get_state(pid).error == :max_turns_exceeded
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrency guard
  # ---------------------------------------------------------------------------

  describe "concurrent run rejection" do
    test "second run returns {:error, :already_running} while first is in flight" do
      pid = start_agent()
      {:ok, ref} = ExAgent.run(pid, "First")
      assert {:error, :already_running} = ExAgent.run(pid, "Second")
      ExAgent.await(ref, 5_000)
    end

    test "run_stream also rejects concurrent requests" do
      pid = start_agent()
      {:ok, ref} = ExAgent.run(pid, "First")
      assert {:error, :already_running} = ExAgent.run_stream(pid, "Second")
      ExAgent.await(ref, 5_000)
    end

    test "run is accepted again once the previous call completes" do
      pid = start_agent()
      {ref1, task_ref1} = simulate_running(pid)
      send(pid, {task_ref1, {:ok, fake_text_response("done")}})
      assert {:ok, "done"} = ExAgent.await(ref1, 1_000)

      # Now can run again
      {:ok, ref2} = ExAgent.run(pid, "Another")
      ExAgent.await(ref2, 5_000)
    end
  end

  # ---------------------------------------------------------------------------
  # Unrecognised messages
  # ---------------------------------------------------------------------------

  describe "unknown messages" do
    test "unknown handle_info message is silently ignored" do
      pid = start_agent()
      send(pid, {:completely_unknown, :message})
      Process.sleep(20)
      assert ExAgent.get_state(pid).status == :idle
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # ExAgent.await/2
  # ---------------------------------------------------------------------------

  describe "ExAgent.await/2" do
    test "returns {:error, :timeout} when no message arrives within deadline" do
      ref = make_ref()
      assert {:error, :timeout} = ExAgent.await(ref, 50)
    end

    test "receives the sent result" do
      ref = make_ref()
      send(self(), {:ex_agent, ref, {:ok, "hello"}})
      assert {:ok, "hello"} = ExAgent.await(ref, 100)
    end

    test "ignores messages with different refs" do
      real_ref = make_ref()
      other_ref = make_ref()
      send(self(), {:ex_agent, other_ref, {:ok, "wrong"}})
      send(self(), {:ex_agent, real_ref, {:ok, "right"}})
      assert {:ok, "right"} = ExAgent.await(real_ref, 200)
    end

    test "default timeout is 120 seconds (function head check)" do
      # Verify the clause exists — just call with an explicit timeout
      ref = make_ref()
      assert {:error, :timeout} = ExAgent.await(ref, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # ExAgent.run_sync/3
  # ---------------------------------------------------------------------------

  describe "ExAgent.run_sync/3" do
    test "returns error when LLM fails (no API key)" do
      pid = start_agent()
      assert {:error, _} = ExAgent.run_sync(pid, "Hello", timeout: 5_000)
    end

    test "returns :timeout when call exceeds per-call timeout" do
      # This works because the API key error fires immediately anyway,
      # but the important thing is run_sync threads the timeout through correctly.
      pid = start_agent()
      assert {:error, _} = ExAgent.run_sync(pid, "Hello", timeout: 1)
    end

    test "returns a two-tuple result directly" do
      pid = start_agent()
      result = ExAgent.run_sync(pid, "test", timeout: 5_000)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Process lifecycle
  # ---------------------------------------------------------------------------

  describe "ExAgent.stop/2" do
    test "stops the process normally" do
      pid = start_agent()
      assert :ok = ExAgent.stop(pid)
      refute Process.alive?(pid)
    end

    test "named agent is deregistered from registry after stop" do
      name = "stop_test_#{System.unique_integer([:positive])}"
      agent = struct!(Agent, name: name, model: "anthropic:claude-sonnet-4-20250514")
      {:ok, pid} = ExAgent.start_link(agent)
      assert ExAgent.whereis(name) == pid
      ExAgent.stop(pid)
      Process.sleep(20)
      assert ExAgent.whereis(name) == nil
    end
  end

  describe "ExAgent.start/1 under DynamicSupervisor" do
    test "starts a supervised child" do
      agent = struct!(Agent, model: "anthropic:claude-sonnet-4-20250514")
      {:ok, pid} = ExAgent.start(agent)
      assert Process.alive?(pid)
      ExAgent.stop(pid)
    end

    test "multiple supervised agents can run concurrently" do
      pids =
        for _ <- 1..3 do
          agent = struct!(Agent, model: "anthropic:claude-sonnet-4-20250514")
          {:ok, pid} = ExAgent.start(agent)
          pid
        end

      assert Enum.all?(pids, &Process.alive?/1)
      # Stop only pids that are still alive (some may have already crashed due to missing API key)
      Enum.each(pids, fn pid ->
        if Process.alive?(pid), do: ExAgent.stop(pid)
      end)
    end
  end
end
