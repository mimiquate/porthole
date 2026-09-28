defmodule Porthole.Error do
  @moduledoc """
  An agent-facing error: a stable `reason` to match on, and a `message` that
  says what went wrong and how to fix the query.
  """

  @type reason ::
          :sql_error
          | :read_only
          | :window_required
          | :not_allowed
          | :not_enabled
          | :bad_request
          | :timeout
          | :rate_limited
          | :busy

  @type t :: %__MODULE__{reason: reason(), message: String.t()}

  defexception [:reason, :message]

  @doc false
  @spec new(reason(), String.t()) :: t()
  def new(reason, message), do: %__MODULE__{reason: reason, message: message}
end
