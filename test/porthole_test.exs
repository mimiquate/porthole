defmodule PortholeTest do
  use ExUnit.Case
  doctest Porthole

  test "greets the world" do
    assert Porthole.hello() == :world
  end
end
