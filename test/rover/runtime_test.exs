defmodule Rover.RuntimeTest do
  use ExUnit.Case, async: false

  alias Rover.Runtime

  describe "binary_path/0" do
    setup do
      original = System.get_env("ROVER_RUNTIME_BIN")
      on_exit(fn -> restore_env("ROVER_RUNTIME_BIN", original) end)
      :ok
    end

    test "honours ROVER_RUNTIME_BIN when set and executable" do
      binary = System.find_executable("sh")
      assert is_binary(binary), "sh should exist on any POSIX system"

      System.put_env("ROVER_RUNTIME_BIN", binary)
      assert {:ok, ^binary} = Runtime.binary_path()
    end

    test "ignores ROVER_RUNTIME_BIN when path does not exist" do
      fake = "/definitely/not/a/real/path/rover_runtime"
      System.put_env("ROVER_RUNTIME_BIN", fake)

      # The env var should NOT be honoured. Either a fallback candidate
      # (the target/debug or target/release build) resolves, or nothing does —
      # both are fine for this test; the key guarantee is that the invalid
      # env path isn't returned.
      case Runtime.binary_path() do
        :error -> :ok
        {:ok, path} -> refute path == fake
      end
    end

    test "ignores ROVER_RUNTIME_BIN when path is not executable" do
      not_executable =
        Path.join(System.tmp_dir!(), "rover_not_executable_#{System.unique_integer([:positive])}")

      File.write!(not_executable, "not an executable")
      File.chmod!(not_executable, 0o644)

      System.put_env("ROVER_RUNTIME_BIN", not_executable)

      on_exit(fn -> File.rm(not_executable) end)

      case Runtime.binary_path() do
        :error -> :ok
        {:ok, path} -> refute path == not_executable
      end
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
