defmodule Rover.Error do
  @moduledoc """
  Structured error returned by `Rover` functions.

  `Rover.fetch/2` and browser commands return `{:error, %Rover.Error{}}` on
  failure — never raise. Pattern match on `:reason` to dispatch recovery:

      case Rover.fetch(url) do
        {:ok, result} ->
          handle(result)

        {:error, %Rover.Error{reason: :timeout}} ->
          Logger.warning("slow page: \#{url}")
          :skip

        {:error, %Rover.Error{reason: :proxy}} ->
          retry_direct(url)
      end

  ## Reason atoms

    * `:timeout` — page load exceeded the configured timeout.
    * `:navigation` — URL could not be reached (DNS, TLS, connection reset).
    * `:selector_not_found` — a selector expected by the operation did not match.
    * `:selector_timeout` — `wait_for` selector did not appear in time.
    * `:evaluation` — JavaScript evaluation threw.
    * `:proxy` — proxy connection failed.
    * `:invalid_argument` — malformed argument (bad URL, unknown option, etc.).
    * `:runtime` — internal runtime error (NIF / subprocess / wire protocol).
    * `:shutdown` — runtime is shutting down and refused the request.
    * `:port_died` — the runtime subprocess exited unexpectedly.
  """

  @reason_tags %{
    "timeout" => :timeout,
    "navigation" => :navigation,
    "selector_not_found" => :selector_not_found,
    "selector_timeout" => :selector_timeout,
    "evaluation" => :evaluation,
    "proxy" => :proxy,
    "invalid_argument" => :invalid_argument,
    "runtime" => :runtime,
    "shutdown" => :shutdown
  }

  defexception [:reason, :message]

  @type reason ::
          :timeout
          | :navigation
          | :selector_not_found
          | :selector_timeout
          | :evaluation
          | :proxy
          | :invalid_argument
          | :runtime
          | :shutdown
          | :port_died

  @type t :: %__MODULE__{reason: reason(), message: String.t()}

  @impl true
  def exception(opts) when is_list(opts) do
    reason = Keyword.fetch!(opts, :reason)
    message = Keyword.get(opts, :message, default_message(reason))
    %__MODULE__{reason: reason, message: message}
  end

  def exception(%{"kind" => tag, "message" => message}) when is_binary(tag) do
    reason = Map.get(@reason_tags, tag, :runtime)
    %__MODULE__{reason: reason, message: message}
  end

  @doc """
  Build an error from the runtime's wire representation.
  """
  @spec from_wire(map()) :: t()
  def from_wire(%{"kind" => tag, "message" => message}) do
    %__MODULE__{
      reason: Map.get(@reason_tags, tag, :runtime),
      message: to_string(message)
    }
  end

  @doc false
  @spec port_died(term()) :: t()
  def port_died(details) do
    %__MODULE__{
      reason: :port_died,
      message: "rover_runtime exited unexpectedly: #{inspect(details)}"
    }
  end

  defp default_message(reason), do: Atom.to_string(reason) |> String.replace("_", " ")
end
