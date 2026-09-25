defmodule Porthole.Test.Secret do
  @moduledoc false
  # A struct that hides a field from Inspect, to check that rendered terms
  # respect custom Inspect implementations.
  @derive {Inspect, except: [:token]}
  defstruct [:user, :token]
end
