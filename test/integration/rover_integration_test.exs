defmodule Rover.IntegrationTest do
  # Integration tests exercise the full stack: Elixir → Port → Rust runtime →
  # Servo. They require the `rover_runtime` binary (build with `mix rover.build`)
  # and are skipped by default. Run with `mix test --include integration`.

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: :timer.minutes(2)

  setup_all do
    case Rover.Runtime.binary_path() do
      :error ->
        raise """
        Integration tests require the rover_runtime binary.
        Build it with:

            cd native/rover_runtime && cargo build

        Or set ROVER_RUNTIME_BIN to an absolute path.
        """

      {:ok, _} ->
        :ok
    end

    {:ok, server} = Rover.Test.Server.start_link()
    on_exit(fn -> Rover.Test.Server.stop(server) end)

    {:ok, base_url: "http://127.0.0.1:#{server.port}"}
  end

  describe "Rover.fetch/2" do
    test "returns rendered HTML for a plain page", %{base_url: base_url} do
      assert {:ok, %Rover.Result{status: :ok, title: "Plain", body: body, url: url}} =
               Rover.fetch(base_url <> "/plain")

      assert body =~ "Hello, Rover."
      assert url =~ "/plain"
    end

    test "waits for JS-mutated content with :wait_for", %{base_url: base_url} do
      assert {:ok, %Rover.Result{status: :ok, title: title, body: body}} =
               Rover.fetch(base_url <> "/rendered",
                 wait_for: "#js-ready",
                 wait_timeout: 10_000
               )

      assert title == "Rendered"
      assert body =~ "Ready"
      assert body =~ "js ran"
    end

    test "evaluate returns a typed JS value", %{base_url: base_url} do
      assert {:ok, %Rover.Result{evaluated: 42}} =
               Rover.fetch(base_url <> "/plain", evaluate: "6 * 7")

      assert {:ok, %Rover.Result{evaluated: "Rover"}} =
               Rover.fetch(base_url <> "/plain", evaluate: "'Rover'")
    end

    test "extract returns a map keyed by selector", %{base_url: base_url} do
      assert {:ok, %Rover.Result{extracted: extracted}} =
               Rover.fetch(base_url <> "/rendered",
                 wait_for: "ul.items li",
                 extract: [greeting: "h1.greeting", items: "ul.items li"]
               )

      # /rendered has no h1.greeting — should not crash; fetches empty for missing.
      # items should return the three <li> texts.
      assert extracted[:items] == ["One", "Two", "Three"]
    end

    test "screenshot returns non-empty PNG bytes", %{base_url: base_url} do
      assert {:ok, %Rover.Result{screenshot: bytes}} =
               Rover.fetch(base_url <> "/plain", screenshot: :png)

      assert is_binary(bytes)
      assert byte_size(bytes) > 0
      # PNG files start with the 8-byte signature.
      assert <<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>> = bytes
    end

    test "malformed URL surfaces Servo's error page (doesn't crash)" do
      # Servo's behaviour on an unsupported scheme is to load an internal
      # error page rather than fail the fetch. That's a reasonable default
      # — the caller can still inspect the title / body.
      assert {:ok, %Rover.Result{status: :ok, title: title}} = Rover.fetch("not-a-url://")
      assert title =~ "Error"
    end

    test "returns :timeout when the server hangs", %{base_url: base_url} do
      assert {:error, %Rover.Error{reason: :timeout}} =
               Rover.fetch(base_url <> "/slow?ms=5000", timeout: 500)
    end
  end

  describe "Rover.Browser long-lived session" do
    setup %{base_url: base_url} do
      {:ok, browser} = Rover.start_link()
      on_exit(fn -> Rover.stop(browser) end)
      {:ok, browser: browser, base_url: base_url}
    end

    test "navigate + content", %{browser: browser, base_url: base_url} do
      assert {:ok, %{url: url, title: "Plain"}} = Rover.navigate(browser, base_url <> "/plain")
      assert url =~ "/plain"

      assert {:ok, body} = Rover.content(browser)
      assert body =~ "Hello, Rover."
    end

    test "fill + click completes a form roundtrip", %{browser: browser, base_url: base_url} do
      assert {:ok, _} = Rover.navigate(browser, base_url <> "/form")

      assert {:ok, :ok} = Rover.fill(browser, "#email", "james@example.com")
      assert {:ok, :ok} = Rover.select_option(browser, "#country", "US")
      assert {:ok, :ok} = Rover.click(browser, "#submit")
      assert {:ok, :ok} = Rover.wait_for(browser, "#echo-email", timeout: 5_000)

      assert {:ok, "james@example.com"} = Rover.get_text(browser, "#echo-email")
      assert {:ok, "US"} = Rover.get_text(browser, "#echo-country")
    end

    test "cookies round-trip", %{browser: browser, base_url: base_url} do
      assert {:ok, _} = Rover.navigate(browser, base_url <> "/cookie-jar")
      assert {:ok, cookies} = Rover.get_cookies(browser)

      assert Enum.any?(cookies, fn c ->
               c["name"] == "rover_tracker" && c["value"] == "baked"
             end)
    end
  end
end
