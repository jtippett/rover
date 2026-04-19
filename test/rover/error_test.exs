defmodule Rover.ErrorTest do
  use ExUnit.Case, async: true

  alias Rover.Error

  describe "from_wire/1" do
    test "maps known tags to reason atoms" do
      for {tag, reason} <- [
            {"timeout", :timeout},
            {"navigation", :navigation},
            {"selector_not_found", :selector_not_found},
            {"selector_timeout", :selector_timeout},
            {"evaluation", :evaluation},
            {"proxy", :proxy},
            {"invalid_argument", :invalid_argument},
            {"runtime", :runtime},
            {"shutdown", :shutdown}
          ] do
        error = Error.from_wire(%{"kind" => tag, "message" => "details"})
        assert %Error{reason: ^reason, message: "details"} = error
      end
    end

    test "unknown tag falls back to :runtime" do
      error = Error.from_wire(%{"kind" => "brand_new_thing", "message" => "oops"})
      assert %Error{reason: :runtime, message: "oops"} = error
    end
  end

  describe "exception/1" do
    test "builds from reason keyword" do
      error = Error.exception(reason: :timeout, message: "slow")
      assert %Error{reason: :timeout, message: "slow"} = error
    end

    test "builds from wire map" do
      error = Error.exception(%{"kind" => "proxy", "message" => "econnrefused"})
      assert %Error{reason: :proxy, message: "econnrefused"} = error
    end

    test "default message when omitted" do
      error = Error.exception(reason: :selector_not_found)
      assert %Error{reason: :selector_not_found, message: "selector not found"} = error
    end
  end

  test "port_died/1 flags reason" do
    error = Error.port_died({:exit_status, 139})
    assert %Error{reason: :port_died} = error
    assert error.message =~ "rover_runtime exited"
  end
end
