defmodule Rover.Result do
  @moduledoc """
  Result of a `Rover.fetch/2` call.

  Every field is a plain value — results are safe to pattern match, serialize,
  and pass across processes.

  ## Fields

    * `:status` — `:ok` when the fetch completed, `:error` otherwise. Mirrors
      the tuple returned by `Rover.fetch/2`, so pipelines that do not pattern
      match the tuple can still branch on `result.status`.
    * `:url` — final URL after redirects.
    * `:body` — rendered HTML (`document.documentElement.outerHTML`), or `nil`
      if the fetch failed before page load.
    * `:title` — `document.title` (may be empty string).
    * `:evaluated` — JS evaluation result if `:evaluate` was requested.
    * `:extracted` — map of selector results if `:extract` was requested.
    * `:screenshot` — raw image bytes if `:screenshot` was requested.
    * `:error` — the `Rover.Error` if `:status == :error`; otherwise `nil`.
  """

  @type t :: %__MODULE__{
          status: :ok | :error,
          url: String.t() | nil,
          body: String.t() | nil,
          title: String.t() | nil,
          evaluated: term() | nil,
          extracted: map() | nil,
          screenshot: binary() | nil,
          error: Rover.Error.t() | nil
        }

  defstruct status: :ok,
            url: nil,
            body: nil,
            title: nil,
            evaluated: nil,
            extracted: nil,
            screenshot: nil,
            error: nil
end
