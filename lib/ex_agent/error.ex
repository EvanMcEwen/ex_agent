defmodule ExAgent.Error do
  @moduledoc """
  Exception struct for ExAgent errors.
  """

  defexception [:reason, :context]

  @impl true
  def message(%{reason: reason}) do
    "ExAgent error: #{inspect(reason)}"
  end
end
