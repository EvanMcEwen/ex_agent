defmodule ExAgent.Tools.Todo do
  @moduledoc """
  `ReqLLM.Tool` definitions for todo CRUD operations.

  Pass a store backend module to `tools/1` — the store process is started
  automatically and closed over by each tool callback.

  ## Usage

      agent = %ExAgent.Agent{
        model: "anthropic:claude-sonnet-4-20250514",
        tools: ExAgent.Tools.Todo.tools(ExAgent.Tools.Todo.Store.InMemory)
      }

  ## Tools

    * `todo_create` — create a new todo with content and optional tags
    * `todo_list`   — list all todos, optionally filtered by tag
    * `todo_update` — update content, tags, or done status by id
    * `todo_delete` — delete a todo by id
  """

  alias ExAgent.Tools.Todo.Store

  @doc """
  Starts a store backed by `backend` and returns the four CRUD tools.
  Accepts an optional `opts` keyword list forwarded to `Store.new/2`.
  """
  @spec tools(module(), keyword()) :: [ReqLLM.Tool.t()]
  def tools(backend, opts \\ []) when is_atom(backend) do
    {:ok, store} = Store.new(backend, opts)

    [
      create_tool(store),
      list_tool(store),
      update_tool(store),
      delete_tool(store)
    ]
  end

  defp create_tool(store) do
    ReqLLM.Tool.new!(
      name: "todo_create",
      description: "Create a new todo item. Returns the created todo including its ID.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "The text of the todo item"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Optional tags that categorize the todo into named lists"
          }
        },
        "required" => ["content"]
      },
      callback: fn args ->
        content = args["content"]
        tags = args["tags"] || []

        case Store.create(store, content, tags) do
          {:ok, item} -> {:ok, Jason.encode!(item)}
          error -> error
        end
      end
    )
  end

  defp list_tool(store) do
    ReqLLM.Tool.new!(
      name: "todo_list",
      description:
        "List todo items. Omit `tag` to return all todos, or provide a tag to filter to a specific list.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "tag" => %{
            "type" => "string",
            "description" => "Return only todos that include this tag"
          }
        }
      },
      callback: fn args ->
        case Store.list(store, args["tag"]) do
          {:ok, items} -> {:ok, Jason.encode!(items)}
          error -> error
        end
      end
    )
  end

  defp update_tool(store) do
    ReqLLM.Tool.new!(
      name: "todo_update",
      description:
        "Update a todo item by ID. Provide any combination of `content`, `tags`, and `done` to change.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "The ID of the todo to update"
          },
          "content" => %{
            "type" => "string",
            "description" => "New text for the todo"
          },
          "tags" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Replacement tag list for the todo"
          },
          "done" => %{
            "type" => "boolean",
            "description" => "Whether the todo is completed"
          }
        },
        "required" => ["id"]
      },
      callback: fn args ->
        id = args["id"]
        changes = Map.take(args, ["content", "tags", "done"])

        case Store.update(store, id, changes) do
          {:ok, item} -> {:ok, Jason.encode!(item)}
          error -> error
        end
      end
    )
  end

  defp delete_tool(store) do
    ReqLLM.Tool.new!(
      name: "todo_delete",
      description: "Delete a todo item by ID.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "id" => %{
            "type" => "string",
            "description" => "The ID of the todo to delete"
          }
        },
        "required" => ["id"]
      },
      callback: fn args ->
        case Store.delete(store, args["id"]) do
          :ok -> {:ok, Jason.encode!(%{deleted: true})}
          error -> error
        end
      end
    )
  end
end
