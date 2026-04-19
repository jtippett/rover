defmodule RoverTest do
  use ExUnit.Case, async: true

  describe "fetch/2 option validation" do
    test "rejects unknown options" do
      assert {:error, %Rover.Error{reason: :invalid_argument, message: message}} =
               Rover.fetch("https://example.com", some_nonsense: true)

      assert message =~ "some_nonsense"
    end

    test "rejects malformed viewport" do
      assert {:error, %Rover.Error{reason: :invalid_argument}} =
               Rover.fetch("https://example.com", viewport: {"a", "b"})
    end

    test "rejects malformed timeout" do
      assert {:error, %Rover.Error{reason: :invalid_argument}} =
               Rover.fetch("https://example.com", timeout: 0)
    end

    test "rejects non-keyword extract" do
      assert {:error, %Rover.Error{reason: :invalid_argument}} =
               Rover.fetch("https://example.com", extract: "not a keyword list")
    end

    test "accepts well-formed options (runtime failure is expected)" do
      # The options parse fine; failure comes later from the missing runtime binary.
      # We just want to confirm the error is *not* :invalid_argument.
      result =
        Rover.fetch("https://example.com",
          proxy: "http://proxy.local:8080",
          timeout: 5_000,
          wait_for: "#root",
          wait_timeout: 1_000,
          evaluate: "document.title",
          extract: [title: "h1"],
          user_agent: "Rover-Test/0",
          viewport: {1024, 768},
          screenshot: :png,
          runtime_path: "/definitely/not/a/real/binary"
        )

      assert {:error, %Rover.Error{reason: reason}} = result
      refute reason == :invalid_argument
    end
  end
end
