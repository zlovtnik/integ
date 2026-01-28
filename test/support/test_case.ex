defmodule GprintEx.TestCase do
  @moduledoc """
  Base test case module for GprintEx tests.

  Provides common imports and setup for unit tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import GprintEx.TestFactory
      alias GprintEx.Result
    end
  end
end
