defmodule Rover.Protocol do
  @moduledoc false
  # Wire format mirror of `native/rover_runtime/src/protocol.rs`.
  #
  # Every frame on the wire is length-prefixed (u32 big-endian) — the Port
  # handles that framing via `packet: 4`. This module deals only with the
  # MessagePack payload inside each frame.
  #
  # Outbound (Elixir → runtime):
  #     %{"id" => <non-zero>, "op" => "navigate", "url" => "...", ...}
  #
  # Inbound (runtime → Elixir):
  #     # response to request <id>
  #     %{"id" => <non-zero>, "kind" => "response", "response" => %{"kind" => "ack"}}
  #
  #     # out-of-band notification (id = 0)
  #     %{"id" => 0, "kind" => "notification",
  #       "notification" => %{"kind" => "hello", ...}}

  @protocol_version 1

  def protocol_version, do: @protocol_version

  @typedoc "Opaque request payload — anything `encode_request/2` accepts."
  @type request ::
          {:init, keyword()}
          | {:navigate, String.t(), timeout :: pos_integer()}
          | :current_url
          | :content
          | :title
          | {:evaluate, String.t()}
          | {:wait_for, String.t(), timeout :: pos_integer()}
          | {:get_text, String.t()}
          | {:get_texts, String.t()}
          | {:get_attribute, String.t(), String.t()}
          | {:click, String.t()}
          | {:fill, String.t(), String.t()}
          | {:hover, String.t()}
          | {:select_option, String.t(), String.t()}
          | {:screenshot, :png | :jpeg, byte()}
          | :get_cookies
          | {:set_cookie, String.t()}
          | :clear_cookies
          | :shutdown

  @doc """
  Serialize a request for sending. Returns the MessagePack binary (no framing).
  """
  @spec encode_request(non_neg_integer(), request()) :: binary()
  def encode_request(id, request) when is_integer(id) and id > 0 do
    request
    |> request_map()
    |> Map.put("id", id)
    |> Msgpax.pack!(iodata: false)
  end

  @doc """
  Decode a MessagePack payload received from the runtime.

  Returns:

    * `{:response, id, response}` — reply to a prior request
    * `{:notification, notification}` — out-of-band event

  Raises `Msgpax.UnpackError` on malformed frames — the caller should trap and
  treat the port as dead.
  """
  @spec decode(binary()) ::
          {:response, pos_integer(), response :: map()}
          | {:notification, notification :: map()}
  def decode(binary) when is_binary(binary) do
    case Msgpax.unpack!(binary) do
      %{"kind" => "response", "id" => id, "response" => response} when id > 0 ->
        {:response, id, response}

      %{"kind" => "notification", "notification" => notification} ->
        {:notification, notification}
    end
  end

  # ── request_map ────────────────────────────────────────────────────────────

  defp request_map({:init, opts}) do
    %{
      "op" => "init",
      "proxy" => Keyword.get(opts, :proxy, ""),
      "user_agent" => Keyword.get(opts, :user_agent),
      "viewport" =>
        case Keyword.get(opts, :viewport) do
          {w, h} -> %{"width" => w, "height" => h}
          nil -> nil
        end
    }
  end

  defp request_map({:navigate, url, timeout_ms}),
    do: %{"op" => "navigate", "url" => url, "timeout_ms" => timeout_ms}

  defp request_map(:current_url), do: %{"op" => "current_url"}
  defp request_map(:content), do: %{"op" => "content"}
  defp request_map(:title), do: %{"op" => "title"}

  defp request_map({:evaluate, expr}),
    do: %{"op" => "evaluate", "expression" => expr}

  defp request_map({:wait_for, selector, timeout_ms}),
    do: %{"op" => "wait_for", "selector" => selector, "timeout_ms" => timeout_ms}

  defp request_map({:get_text, selector}),
    do: %{"op" => "get_text", "selector" => selector}

  defp request_map({:get_texts, selector}),
    do: %{"op" => "get_texts", "selector" => selector}

  defp request_map({:get_attribute, selector, name}),
    do: %{"op" => "get_attribute", "selector" => selector, "name" => name}

  defp request_map({:click, selector}),
    do: %{"op" => "click", "selector" => selector}

  defp request_map({:fill, selector, value}),
    do: %{"op" => "fill", "selector" => selector, "value" => value}

  defp request_map({:hover, selector}),
    do: %{"op" => "hover", "selector" => selector}

  defp request_map({:select_option, selector, value}),
    do: %{"op" => "select_option", "selector" => selector, "value" => value}

  defp request_map({:screenshot, format, quality})
       when format in [:png, :jpeg] and quality in 1..100 do
    %{"op" => "screenshot", "format" => Atom.to_string(format), "quality" => quality}
  end

  defp request_map(:get_cookies), do: %{"op" => "get_cookies"}

  defp request_map({:set_cookie, cookie}),
    do: %{"op" => "set_cookie", "cookie" => cookie}

  defp request_map(:clear_cookies), do: %{"op" => "clear_cookies"}
  defp request_map(:shutdown), do: %{"op" => "shutdown"}
end
