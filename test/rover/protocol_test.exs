defmodule Rover.ProtocolTest do
  use ExUnit.Case, async: true

  alias Rover.Protocol

  describe "encode_request/2" do
    test "encodes init with proxy and user agent" do
      payload =
        Protocol.encode_request(
          1,
          {:init, proxy: "http://127.0.0.1:3128", user_agent: "Rover/1.0"}
        )

      assert %{
               "id" => 1,
               "op" => "init",
               "proxy" => "http://127.0.0.1:3128",
               "user_agent" => "Rover/1.0"
             } = Msgpax.unpack!(payload)
    end

    test "encodes init with viewport" do
      payload = Protocol.encode_request(2, {:init, viewport: {800, 600}})

      assert %{
               "op" => "init",
               "viewport" => %{"width" => 800, "height" => 600}
             } = Msgpax.unpack!(payload)
    end

    test "encodes init without proxy as empty string" do
      payload = Protocol.encode_request(3, {:init, []})
      assert %{"proxy" => ""} = Msgpax.unpack!(payload)
    end

    test "encodes navigate with timeout" do
      payload = Protocol.encode_request(7, {:navigate, "https://example.com", 15_000})

      assert %{
               "id" => 7,
               "op" => "navigate",
               "url" => "https://example.com",
               "timeout_ms" => 15_000
             } = Msgpax.unpack!(payload)
    end

    test "encodes simple atom-only requests" do
      for {atom, op} <- [
            {:content, "content"},
            {:title, "title"},
            {:current_url, "current_url"},
            {:get_cookies, "get_cookies"},
            {:clear_cookies, "clear_cookies"},
            {:shutdown, "shutdown"}
          ] do
        payload = Protocol.encode_request(42, atom)
        assert %{"op" => ^op, "id" => 42} = Msgpax.unpack!(payload)
      end
    end

    test "encodes interaction requests" do
      assert %{"op" => "click", "selector" => "button.primary"} =
               Protocol.encode_request(1, {:click, "button.primary"}) |> Msgpax.unpack!()

      assert %{"op" => "fill", "selector" => "#email", "value" => "x@y"} =
               Protocol.encode_request(1, {:fill, "#email", "x@y"}) |> Msgpax.unpack!()

      assert %{"op" => "hover", "selector" => ".tooltip"} =
               Protocol.encode_request(1, {:hover, ".tooltip"}) |> Msgpax.unpack!()

      assert %{"op" => "select_option", "selector" => "#country", "value" => "IE"} =
               Protocol.encode_request(1, {:select_option, "#country", "IE"}) |> Msgpax.unpack!()
    end

    test "encodes screenshot with format and quality" do
      payload = Protocol.encode_request(1, {:screenshot, :jpeg, 70})

      assert %{"op" => "screenshot", "format" => "jpeg", "quality" => 70} =
               Msgpax.unpack!(payload)
    end

    test "rejects id 0 (reserved for notifications)" do
      assert_raise FunctionClauseError, fn ->
        Protocol.encode_request(0, :content)
      end
    end
  end

  describe "decode/1" do
    test "decodes a response envelope" do
      frame =
        Msgpax.pack!(%{
          "id" => 7,
          "kind" => "response",
          "response" => %{"kind" => "ack"}
        })

      assert {:response, 7, %{"kind" => "ack"}} = Protocol.decode(IO.iodata_to_binary(frame))
    end

    test "decodes a notification envelope" do
      frame =
        Msgpax.pack!(%{
          "id" => 0,
          "kind" => "notification",
          "notification" => %{
            "kind" => "hello",
            "protocol_version" => 1,
            "runtime_version" => "0.1.0"
          }
        })

      assert {:notification,
              %{
                "kind" => "hello",
                "protocol_version" => 1,
                "runtime_version" => "0.1.0"
              }} = Protocol.decode(IO.iodata_to_binary(frame))
    end

    test "decodes an error response" do
      frame =
        Msgpax.pack!(%{
          "id" => 3,
          "kind" => "response",
          "response" => %{
            "kind" => "error",
            "error" => %{"kind" => "timeout", "message" => "deadline exceeded"}
          }
        })

      assert {:response, 3,
              %{
                "kind" => "error",
                "error" => %{"kind" => "timeout", "message" => "deadline exceeded"}
              }} = Protocol.decode(IO.iodata_to_binary(frame))
    end
  end
end
