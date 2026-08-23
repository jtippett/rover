defmodule Rover.Test.Proxy do
  @moduledoc false

  # A deliberately tiny HTTP proxy fixture. It terminates every request with a
  # marker page instead of forwarding it, which lets integration tests prove
  # which proxy a Rover.Browser actually used without relying on external DNS or
  # network access.

  use GenServer

  @type t :: pid()

  @spec start(String.t()) :: GenServer.on_start()
  def start(marker) when is_binary(marker) do
    GenServer.start(__MODULE__, marker)
  end

  @spec stop(t()) :: :ok
  def stop(proxy) do
    GenServer.stop(proxy)
  catch
    :exit, _reason -> :ok
  end

  @spec url(t()) :: String.t()
  def url(proxy), do: GenServer.call(proxy, :url)

  @spec requests(t()) :: [String.t()]
  def requests(proxy), do: GenServer.call(proxy, :requests)

  @impl true
  def init(marker) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    owner = self()
    acceptor = spawn_link(fn -> accept_loop(listener, owner, marker) end)

    {:ok, %{listener: listener, acceptor: acceptor, marker: marker, port: port, requests: []}}
  end

  @impl true
  def handle_call(:url, _from, state) do
    {:reply, "http://127.0.0.1:#{state.port}", state}
  end

  def handle_call(:requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  @impl true
  def handle_info({:proxy_request, request_line}, state) do
    {:noreply, %{state | requests: [request_line | state.requests]}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)

    if Process.alive?(state.acceptor) do
      Process.exit(state.acceptor, :shutdown)
    end

    :ok
  end

  defp accept_loop(listener, owner, marker) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> serve(socket, owner, marker) end)
        accept_loop(listener, owner, marker)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, owner, marker) do
    with {:ok, request} <- receive_headers(socket, ""),
         [request_line | _] <- String.split(request, "\r\n") do
      send(owner, {:proxy_request, request_line})

      if String.starts_with?(request_line, "CONNECT ") do
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")

        with {:ok, tunneled_request} <- receive_headers(socket, ""),
             [tunneled_request_line | _] <- String.split(tunneled_request, "\r\n") do
          send(owner, {:proxy_request, tunneled_request_line})
          send_marker_page(socket, marker)
        end
      else
        send_marker_page(socket, marker)
      end
    end
  after
    :gen_tcp.close(socket)
  end

  defp send_marker_page(socket, marker) do
    body =
      "<!doctype html><html><head><title>#{marker}</title></head>" <>
        "<body><h1 id=\"proxy-marker\">#{marker}</h1></body></html>"

    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\n",
      "Content-Type: text/html; charset=utf-8\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Connection: close\r\n",
      "\r\n",
      body
    ])
  end

  defp receive_headers(socket, buffer) when byte_size(buffer) <= 16_384 do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, chunk} -> receive_headers(socket, buffer <> chunk)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp receive_headers(_socket, _buffer), do: {:error, :headers_too_large}
end
