defmodule Rover.Browser do
  @moduledoc """
  A long-lived browser session.

  Each `Rover.Browser` owns one `rover_runtime` OS process. The subprocess in
  turn owns exactly one Servo instance and one WebView — so one browser =
  one isolated rendering context with its own proxy, cookies, and network
  state.

  Call `start_link/1` to open a browser, then drive it with the functions in
  the top-level `Rover` module:

      {:ok, browser} = Rover.Browser.start_link(proxy: "http://proxy:8080")
      :ok = Rover.navigate(browser, "https://example.com")
      {:ok, html} = Rover.content(browser)
      Rover.stop(browser)

  The process is meant to be added to your own supervisor. If you just need a
  page's rendered HTML, reach for `Rover.fetch/2` — it spins a browser up,
  runs your operation, and tears it down.

  ## Lifecycle

    * `start_link/1` blocks until the runtime reports `Hello` and accepts its
      `Init`. A failed init returns `{:error, %Rover.Error{}}` — the GenServer
      does not start.
    * If the runtime subprocess crashes, the GenServer exits with reason
      `{:port_died, details}` and pending callers receive
      `{:error, %Rover.Error{reason: :port_died}}`. Use a supervisor to
      restart the browser.
  """

  use GenServer, restart: :transient

  alias Rover.{Error, Protocol}

  require Logger

  @default_call_timeout 60_000

  @doc """
  Start a browser linked to the caller.

  ## Options

    * `:proxy` — HTTP/HTTPS proxy URI (`"http://host:port"` or with
      `"http://user:pass@host:port"`). Baked into the engine for the lifetime
      of this browser. Default: direct (no proxy).
    * `:user_agent` — custom User-Agent string. Default: Servo's default.
    * `:viewport` — `{width, height}` in CSS pixels. Default: `{1280, 720}`.
    * `:name` — standard GenServer registration name.
    * `:runtime_path` — override the path to the runtime binary; useful for
      tests. Default: resolved by `Rover.Runtime`.
    * `:init_timeout` — how long to wait for the runtime to accept `Init`.
      Default: 30s.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, init_opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Shut the browser down cleanly.

  Sends `Shutdown` to the runtime and waits for it to exit, then terminates
  the GenServer. Returns `:ok` even if the runtime was already gone.
  """
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(server, timeout \\ 5_000) do
    try do
      GenServer.stop(server, :normal, timeout)
    catch
      :exit, _ -> :ok
    end
  end

  @doc false
  @spec call(GenServer.server(), Protocol.request(), timeout()) ::
          {:ok, term()} | {:error, Error.t()}
  def call(server, request, timeout \\ @default_call_timeout) do
    # Pad the GenServer.call timeout so the runtime's own deadline fires first —
    # we'd rather hear a typed `{:error, %Error{reason: :timeout}}` than an exit.
    call_timeout = timeout + 5_000

    try do
      GenServer.call(server, {:request, request, timeout}, call_timeout)
    catch
      :exit, {:timeout, _} ->
        {:error,
         Error.exception(
           reason: :timeout,
           message: "Rover.Browser.call timed out after #{call_timeout}ms"
         )}

      :exit, {:noproc, _} ->
        {:error, Error.exception(reason: :runtime, message: "browser is not running")}
    end
  end

  # ── GenServer ──────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    runtime_path =
      case Keyword.fetch(opts, :runtime_path) do
        {:ok, path} -> path
        :error -> resolve_runtime_path()
      end

    init_timeout = Keyword.get(opts, :init_timeout, 30_000)

    with {:ok, path} <- verify_runtime_path(runtime_path),
         {:ok, port} <- open_port(path) do
      state = %{
        port: port,
        next_id: 1,
        pending: %{},
        monitors: %{},
        hello?: false,
        shutting_down?: false
      }

      case wait_for_hello(state, init_timeout) do
        {:ok, state} ->
          case send_init(state, opts, init_timeout) do
            {:ok, state} ->
              {:ok, state}

            {:error, %Error{} = e} ->
              close_port(port)
              {:stop, {:init_failed, e}}
          end

        {:error, %Error{} = e} ->
          close_port(port)
          {:stop, {:init_failed, e}}
      end
    else
      {:error, %Error{} = e} -> {:stop, {:init_failed, e}}
    end
  end

  defp resolve_runtime_path do
    Rover.Runtime.binary_path!()
  rescue
    e in Rover.Error -> {:error, e}
  else
    path when is_binary(path) -> path
  end

  defp verify_runtime_path({:error, %Error{}} = err), do: err

  defp verify_runtime_path(path) when is_binary(path) do
    if File.regular?(path) do
      {:ok, path}
    else
      {:error,
       Error.exception(
         reason: :runtime,
         message: "rover_runtime binary does not exist at #{path}"
       )}
    end
  end

  defp open_port(path) do
    {:ok,
     Port.open({:spawn_executable, path}, [
       :binary,
       {:packet, 4},
       :exit_status,
       :hide,
       :use_stdio,
       # Args: none. All configuration flows via the `Init` request.
       # stderr is intentionally NOT merged — log lines would corrupt
       # the length-prefixed stdout frame stream.
       {:args, []}
     ])}
  rescue
    e in ArgumentError ->
      {:error,
       Error.exception(reason: :runtime, message: "Port.open failed: #{Exception.message(e)}")}
  catch
    :error, reason ->
      {:error, Error.exception(reason: :runtime, message: "Port.open failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_call({:request, request, op_timeout}, from, state) do
    if state.shutting_down? do
      {:reply, {:error, Error.exception(reason: :shutdown, message: "browser is shutting down")},
       state}
    else
      {id, state} = assign_id(state)
      payload = Protocol.encode_request(id, request)
      send_payload(state.port, payload)

      state = put_pending(state, id, from, request, op_timeout)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    case Protocol.decode(data) do
      {:notification, notification} ->
        handle_notification(notification, state)

      {:response, id, response} ->
        handle_response(id, response, state)
    end
  rescue
    e in Msgpax.UnpackError ->
      Logger.error("malformed runtime frame: #{Exception.message(e)}")
      {:stop, {:protocol_error, e}, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Port exited. Reply to anyone waiting and stop.
    error =
      if state.shutting_down? do
        Error.exception(reason: :shutdown, message: "browser shut down")
      else
        Error.port_died({:exit_status, status})
      end

    fail_pending(state, error)

    reason = if state.shutting_down?, do: :normal, else: {:port_died, status}
    {:stop, reason, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    error = Error.port_died({:exit, reason})
    fail_pending(state, error)
    {:stop, {:port_died, reason}, %{state | port: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, %{port: port}) do
    # Best-effort graceful shutdown: ask the runtime to exit, give it a beat,
    # then close the port. Swallow any already-dead errors.
    shutdown_payload = Protocol.encode_request(0xFFFF_FFFF, :shutdown)
    _ = send_payload(port, shutdown_payload)
    close_port(port)
    :ok
  end

  # ── state helpers ──────────────────────────────────────────────────────────

  defp assign_id(%{next_id: id} = state) do
    {id, %{state | next_id: id + 1}}
  end

  defp put_pending(state, id, from, _request, _timeout) do
    %{state | pending: Map.put(state.pending, id, from)}
  end

  defp handle_response(id, response, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        Logger.debug("rover: received response for unknown id #{id} (stale?)")
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, response_to_reply(response))
        {:noreply, %{state | pending: pending}}
    end
  end

  defp response_to_reply(%{"kind" => "ack"}), do: {:ok, :ok}
  defp response_to_reply(%{"kind" => "error"} = frame), do: {:error, decode_error(frame)}

  defp response_to_reply(%{"kind" => "page_info", "url" => url, "title" => title}),
    do: {:ok, %{url: url, title: title}}

  defp response_to_reply(%{"kind" => "text", "string" => s}), do: {:ok, s}
  defp response_to_reply(%{"kind" => "texts", "strings" => s}) when is_list(s), do: {:ok, s}
  defp response_to_reply(%{"kind" => "value", "value" => v}), do: {:ok, decode_value(v)}

  defp response_to_reply(%{"kind" => "image", "bytes" => bytes}),
    do: {:ok, iodata_to_binary(bytes)}

  defp response_to_reply(%{"kind" => "cookies", "cookies" => cookies}), do: {:ok, cookies}

  defp response_to_reply(other) do
    {:error,
     Error.exception(
       reason: :runtime,
       message: "unexpected response shape: #{inspect(other)}"
     )}
  end

  defp decode_error(%{"error" => error}) when is_map(error), do: Error.from_wire(error)
  defp decode_error(%{"kind" => "error"} = frame), do: Error.from_wire(frame)

  defp decode_value(%Msgpax.Bin{data: data}), do: data
  defp decode_value(v), do: v

  defp iodata_to_binary(%Msgpax.Bin{data: data}), do: data
  defp iodata_to_binary(bin) when is_binary(bin), do: bin

  defp handle_notification(%{"kind" => "hello"} = hello, state) do
    Logger.debug("rover: runtime hello #{inspect(hello)}")
    {:noreply, %{state | hello?: true}}
  end

  defp handle_notification(%{"kind" => "log", "level" => level, "message" => message}, state) do
    Logger.log(log_level(level), "rover_runtime: #{message}")
    {:noreply, state}
  end

  defp handle_notification(_other, state), do: {:noreply, state}

  defp log_level("debug"), do: :debug
  defp log_level("info"), do: :info
  defp log_level("warn"), do: :warning
  defp log_level("error"), do: :error
  defp log_level(_), do: :info

  defp fail_pending(%{pending: pending}, error) do
    Enum.each(pending, fn {_id, from} ->
      GenServer.reply(from, {:error, error})
    end)
  end

  # ── port helpers ───────────────────────────────────────────────────────────

  defp send_payload(port, payload) do
    Port.command(port, payload)
  rescue
    ArgumentError -> :port_closed
  end

  defp close_port(port) do
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    :ok
  end

  # ── startup helpers ────────────────────────────────────────────────────────

  defp wait_for_hello(state, timeout) do
    receive do
      {port, {:data, data}} when port == state.port ->
        case Protocol.decode(data) do
          {:notification, %{"kind" => "hello"} = hello} ->
            Logger.debug("rover: runtime hello #{inspect(hello)}")
            {:ok, %{state | hello?: true}}

          _ ->
            # Ignore pre-hello chatter; keep waiting.
            wait_for_hello(state, timeout)
        end

      {port, {:exit_status, status}} when port == state.port ->
        {:error,
         Error.exception(
           reason: :runtime,
           message: "runtime exited before hello (status #{status})"
         )}
    after
      timeout ->
        {:error,
         Error.exception(
           reason: :timeout,
           message: "runtime did not say hello within #{timeout}ms"
         )}
    end
  end

  defp send_init(state, opts, timeout) do
    init_request =
      {:init, Keyword.take(opts, [:proxy, :user_agent, :viewport])}

    {id, state} = assign_id(state)
    payload = Protocol.encode_request(id, init_request)
    send_payload(state.port, payload)

    # Block waiting for the init ack; no handle_call is active yet.
    receive do
      {port, {:data, data}} when port == state.port ->
        case Protocol.decode(data) do
          {:response, ^id, %{"kind" => "ack"}} ->
            {:ok, state}

          {:response, ^id, %{"kind" => "error"} = frame} ->
            {:error, Error.from_wire(frame)}

          {:notification, _} ->
            # A log notification may arrive between init request and ack.
            send_init_continue(state, id, timeout)
        end

      {port, {:exit_status, status}} when port == state.port ->
        {:error,
         Error.exception(
           reason: :runtime,
           message: "runtime exited during init (status #{status})"
         )}
    after
      timeout ->
        {:error,
         Error.exception(
           reason: :timeout,
           message: "runtime did not ack init within #{timeout}ms"
         )}
    end
  end

  defp send_init_continue(state, id, timeout) do
    receive do
      {port, {:data, data}} when port == state.port ->
        case Protocol.decode(data) do
          {:response, ^id, %{"kind" => "ack"}} ->
            {:ok, state}

          {:response, ^id, %{"kind" => "error"} = frame} ->
            {:error, Error.from_wire(frame)}

          {:notification, _} ->
            send_init_continue(state, id, timeout)
        end
    after
      timeout ->
        {:error,
         Error.exception(
           reason: :timeout,
           message: "runtime did not ack init within #{timeout}ms"
         )}
    end
  end
end
