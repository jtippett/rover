defmodule Rover.WatchdogTest do
  # The runtime's normal exit paths (Shutdown frame, stdin EOF, stdout write
  # failure) all require the main thread to be back in the wire read loop. If
  # Servo wedges mid-operation, a dead BEAM leaves the runtime orphaned and
  # spinning — the parent-death watchdog is the backstop that must catch it.
  #
  # This test recreates the orphan shape directly: the runtime's parent dies
  # while stdin is deliberately held open by another process, so EOF never
  # arrives and only the watchdog can end the process.

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: :timer.seconds(30)

  test "runtime exits after its parent dies, even with stdin held open" do
    {:ok, bin} = Rover.Runtime.binary_path()

    base = Path.join(System.tmp_dir!(), "rover-wd-#{System.unique_integer([:positive])}")
    fifo = base <> ".fifo"
    holder_pidfile = base <> ".holder.pid"
    runtime_pidfile = base <> ".runtime.pid"

    {_, 0} = System.cmd("mkfifo", [fifo])

    # Both background jobs run inside a subshell redirected to /dev/null so
    # they never inherit the Erlang port's stdout pipe — a child blocked in
    # open(2) on the FIFO would otherwise hold it open and hang System.cmd.

    # Holder keeps the FIFO's write end open so the runtime never sees EOF.
    {_, 0} =
      System.cmd("sh", [
        "-c",
        "( sleep 30 > #{fifo} & echo $! > #{holder_pidfile} ) > /dev/null 2>&1"
      ])

    # This shell is the runtime's parent; it exits as soon as System.cmd
    # returns, orphaning the runtime (re-parented to pid 1) with stdin open.
    {_, 0} =
      System.cmd("sh", [
        "-c",
        "( #{bin} < #{fifo} > /dev/null 2>&1 & echo $! > #{runtime_pidfile} ) > /dev/null 2>&1"
      ])

    holder_pid = File.read!(holder_pidfile) |> String.trim()
    runtime_pid = File.read!(runtime_pidfile) |> String.trim()

    on_exit(fn ->
      System.cmd("kill", [holder_pid], stderr_to_stdout: true)
      Enum.each([fifo, holder_pidfile, runtime_pidfile], &File.rm/1)
    end)

    assert wait_until_dead(runtime_pid, _attempts = 60),
           "rover_runtime #{runtime_pid} survived parent death with stdin open; " <>
             "the parent-death watchdog did not fire (killed it for cleanup)"
  end

  defp wait_until_dead(pid, 0) do
    System.cmd("kill", [pid], stderr_to_stdout: true)
    false
  end

  defp wait_until_dead(pid, attempts) do
    # kill -0 probes liveness; it sends no signal.
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(100)
        wait_until_dead(pid, attempts - 1)

      {_, _} ->
        true
    end
  end
end
