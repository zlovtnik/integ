defmodule GprintEx.ResultTest do
  use ExUnit.Case, async: true

  alias GprintEx.Result

  describe "map/2" do
    test "maps over success value" do
      assert {:ok, 4} = Result.map({:ok, 2}, &(&1 * 2))
    end

    test "returns error unchanged" do
      assert {:error, :reason} = Result.map({:error, :reason}, &(&1 * 2))
    end
  end

  describe "flat_map/2" do
    test "chains successful operations" do
      result =
        {:ok, 2}
        |> Result.flat_map(fn x -> {:ok, x * 2} end)
        |> Result.flat_map(fn x -> {:ok, x + 1} end)

      assert {:ok, 5} = result
    end

    test "short-circuits on error" do
      result =
        {:ok, 2}
        |> Result.flat_map(fn _ -> {:error, :failed} end)
        |> Result.flat_map(fn x -> {:ok, x + 1} end)

      assert {:error, :failed} = result
    end
  end

  describe "unwrap_or/2" do
    test "returns value for success" do
      assert 42 = Result.unwrap_or({:ok, 42}, 0)
    end

    test "returns default for error" do
      assert 0 = Result.unwrap_or({:error, :reason}, 0)
    end
  end

  describe "sequence/1" do
    test "sequences all successes" do
      results = [{:ok, 1}, {:ok, 2}, {:ok, 3}]
      assert {:ok, [1, 2, 3]} = Result.sequence(results)
    end

    test "returns first error" do
      results = [{:ok, 1}, {:error, :bad}, {:ok, 3}]
      assert {:error, :bad} = Result.sequence(results)
    end

    test "handles empty list" do
      assert {:ok, []} = Result.sequence([])
    end
  end

  describe "traverse/2" do
    test "maps and sequences" do
      assert {:ok, [2, 4, 6]} = Result.traverse([1, 2, 3], fn x -> {:ok, x * 2} end)
    end

    test "short-circuits on error" do
      result =
        Result.traverse([1, 2, 3], fn
          2 -> {:error, :two}
          x -> {:ok, x * 2}
        end)

      assert {:error, :two} = result
    end
  end

  describe "from_nilable/2" do
    test "wraps non-nil value in ok" do
      assert {:ok, 42} = Result.from_nilable(42, :not_found)
    end

    test "returns error for nil" do
      assert {:error, :not_found} = Result.from_nilable(nil, :not_found)
    end
  end

  describe "ok?/1 and error?/1" do
    test "ok? returns true for success" do
      assert Result.ok?({:ok, 1})
      refute Result.ok?({:error, :reason})
    end

    test "error? returns true for error" do
      assert Result.error?({:error, :reason})
      refute Result.error?({:ok, 1})
    end
  end

  describe "map2/3" do
    test "combines two successes" do
      assert {:ok, 5} = Result.map2({:ok, 2}, {:ok, 3}, &+/2)
    end

    test "returns first error" do
      assert {:error, :a} = Result.map2({:error, :a}, {:ok, 3}, &+/2)
      assert {:error, :b} = Result.map2({:ok, 2}, {:error, :b}, &+/2)
    end
  end

  describe "tap_ok/2" do
    test "executes side effect for success" do
      parent = self()

      result =
        {:ok, 42}
        |> Result.tap_ok(fn value -> send(parent, {:received, value}) end)

      assert {:ok, 42} = result
      assert_receive {:received, 42}
    end

    test "does not execute for error" do
      parent = self()

      result =
        {:error, :reason}
        |> Result.tap_ok(fn value -> send(parent, {:received, value}) end)

      assert {:error, :reason} = result
      refute_receive {:received, _}
    end
  end
end
