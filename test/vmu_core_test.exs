defmodule VmuCoreTest do
  use ExUnit.Case
  doctest VmuCore

  test "greets the world" do
    assert VmuCore.hello() == :world
  end
end
