defmodule ExAgentTest do
  use ExUnit.Case

  alias ExAgent.{Agent, State}

  describe "Agent struct" do
    test "requires model" do
      assert_raise ArgumentError, fn ->
        struct!(Agent, name: "test")
      end
    end

    test "has sensible defaults" do
      agent = %Agent{model: "anthropic:claude-sonnet-4-20250514"}

      assert agent.name == nil
      assert agent.tools == []
      assert agent.max_turns == 10
      assert agent.timeout == 120_000
      assert agent.generate_opts == []
      assert agent.metadata == %{}
    end
  end

  describe "State" do
    test "new/1 initializes from agent config" do
      agent = %Agent{
        model: "anthropic:claude-sonnet-4-20250514",
        system_prompt: "You are helpful."
      }

      state = State.new(agent)

      assert state.status == :idle
      assert state.turns == 0
      assert state.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0, reasoning_tokens: 0, total_cost: 0.0}
      assert state.error == nil
      assert state.caller == nil
      assert state.task_ref == nil
      assert state.timer_ref == nil

      messages = ReqLLM.Context.to_list(state.context)
      assert length(messages) == 1
      assert hd(messages).role == :system
    end

    test "new/1 without system prompt creates empty context" do
      agent = %Agent{model: "anthropic:claude-sonnet-4-20250514"}
      state = State.new(agent)

      messages = ReqLLM.Context.to_list(state.context)
      assert messages == []
    end

    test "snapshot/1 returns sanitized state map" do
      agent = %Agent{name: "test", model: "anthropic:claude-sonnet-4-20250514"}
      state = State.new(agent)

      snapshot = State.snapshot(state)

      assert snapshot.name == "test"
      assert snapshot.status == :idle
      assert snapshot.turns == 0
      assert snapshot.message_count == 0
      assert snapshot.error == nil
      refute Map.has_key?(snapshot, :caller)
      refute Map.has_key?(snapshot, :task_ref)
    end
  end

  describe "start_link/1 and get_state/1" do
    test "starts an agent process and returns idle state" do
      agent = %Agent{model: "anthropic:claude-sonnet-4-20250514"}
      {:ok, pid} = ExAgent.start_link(agent)

      state = ExAgent.get_state(pid)
      assert state.status == :idle
      assert state.turns == 0

      ExAgent.stop(pid)
    end

    test "named agent can be looked up via whereis" do
      agent = %Agent{name: "lookup_test", model: "anthropic:claude-sonnet-4-20250514"}
      {:ok, pid} = ExAgent.start(agent)

      assert ExAgent.whereis("lookup_test") == pid

      ExAgent.stop(pid)
    end

    test "whereis returns nil for unknown names" do
      assert ExAgent.whereis("nonexistent") == nil
    end
  end

  describe "run/3 is async" do
    test "returns {:ok, ref} immediately without blocking" do
      agent = %Agent{model: "anthropic:claude-sonnet-4-20250514"}
      {:ok, pid} = ExAgent.start_link(agent)

      # run returns immediately — the LLM call will fail but that's fine,
      # we're just testing the async contract
      {:ok, ref} = ExAgent.run(pid, "Hello")
      assert is_reference(ref)

      state = ExAgent.get_state(pid)
      assert state.status == :running

      # Wait for the result (will be an error since no real API key)
      assert {:error, _reason} = ExAgent.await(ref, 5_000)

      ExAgent.stop(pid)
    end

    test "rejects concurrent runs" do
      agent = %Agent{model: "anthropic:claude-sonnet-4-20250514"}
      {:ok, pid} = ExAgent.start_link(agent)

      {:ok, ref} = ExAgent.run(pid, "First")
      assert {:error, :already_running} = ExAgent.run(pid, "Second")

      ExAgent.await(ref, 5_000)
      ExAgent.stop(pid)
    end
  end
end
