defmodule Rover do
  @moduledoc """
  Drive the [Servo](https://servo.org) web engine from Elixir.

  Rover runs each browser as its own OS process, isolated from the BEAM and
  from other browsers — so every browser has its own proxy, cookie jar, and
  network state, and a renderer crash can never take down your VM.

  The API is modelled after [`Req`](https://hexdocs.pm/req): small, composable,
  and sensible by default.

  ## One-shot

      {:ok, result} = Rover.fetch("https://example.com")
      result.body   # rendered HTML
      result.title  # document.title
      result.url    # final URL after redirects

  ## With options

      {:ok, result} =
        Rover.fetch("https://example.com",
          proxy: "http://eu.proxy.example:8080",
          timeout: 15_000,
          wait_for: ".content",
          evaluate: "JSON.stringify(window.__NEXT_DATA__)"
        )

  ## Long-lived browser

      {:ok, browser} = Rover.start_link(proxy: "http://proxy:8080")

      :ok = Rover.navigate(browser, "https://example.com/login")
      :ok = Rover.fill(browser, "#email", "user@example.com")
      :ok = Rover.fill(browser, "#password", "hunter2")
      :ok = Rover.click(browser, "button[type=submit]")
      :ok = Rover.wait_for(browser, ".dashboard")

      {:ok, html} = Rover.content(browser)
      {:ok, png}  = Rover.screenshot(browser)

      Rover.stop(browser)

  See `fetch/2` for the full option list.
  """

  alias Rover.{Browser, Error, Result}

  @default_timeout 30_000

  @fetch_schema [
    proxy: [type: {:or, [:string, nil]}, default: nil],
    user_agent: [type: {:or, [:string, nil]}, default: nil],
    viewport: [type: {:tuple, [:pos_integer, :pos_integer]}, default: {1280, 720}],
    timeout: [type: :pos_integer, default: @default_timeout],
    wait_for: [type: {:or, [:string, nil]}, default: nil],
    wait_timeout: [type: :pos_integer, default: 10_000],
    evaluate: [type: {:or, [:string, nil]}, default: nil],
    extract: [type: {:or, [:keyword_list, nil]}, default: nil],
    screenshot: [
      type: {:or, [:boolean, {:in, [:png, :jpeg]}]},
      default: false
    ],
    runtime_path: [type: {:or, [:string, nil]}, default: nil]
  ]

  @doc """
  Fetch a URL and return a `Rover.Result`.

  Spins up a fresh browser, navigates, applies any requested extraction or
  evaluation, and tears the browser down. For anything more than a handful of
  pages or where startup cost matters, use `start_link/1` and reuse a browser.

  ## Options

    * `:proxy` — HTTP/HTTPS proxy URI (`"http://host:port"` or
      `"http://user:pass@host:port"`). Default: direct.
    * `:timeout` — page-load timeout in ms. Default: `30_000`.
    * `:wait_for` — CSS selector to wait for before reading content.
    * `:wait_timeout` — timeout for `:wait_for` specifically. Default: `10_000`.
    * `:evaluate` — JavaScript expression to evaluate after load; the result
      is placed in `result.evaluated`.
    * `:extract` — keyword list of `[key: "css selector"]`. Each selector's
      `innerText` is captured into `result.extracted.<key>`. Multi-match
      selectors return a list.
    * `:screenshot` — `true` / `:png` for PNG, `:jpeg` for JPEG. The image
      bytes are placed in `result.screenshot`.
    * `:user_agent` — custom User-Agent string.
    * `:viewport` — `{width, height}` in CSS pixels. Default: `{1280, 720}`.
    * `:runtime_path` — override path to the `rover_runtime` binary.

  Returns:

    * `{:ok, %Rover.Result{status: :ok, body: _, ...}}` on success.
    * `{:error, %Rover.Error{}}` on failure. Never raises.

  ## Example

      iex> {:ok, result} = Rover.fetch("https://example.com")
      iex> result.status
      :ok

  """
  @spec fetch(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def fetch(url, opts \\ []) when is_binary(url) do
    case NimbleOptions.validate(opts, @fetch_schema) do
      {:ok, opts} ->
        do_fetch(url, opts)

      {:error, %NimbleOptions.ValidationError{message: message}} ->
        {:error, Error.exception(reason: :invalid_argument, message: message)}
    end
  end

  defp do_fetch(url, opts) do
    browser_opts =
      opts
      |> Keyword.take([:proxy, :user_agent, :viewport, :runtime_path])
      |> Keyword.reject(fn {_, v} -> is_nil(v) end)

    # Use `start` (not `start_link`) so an init failure returns a tagged error
    # instead of killing the caller. The browser's lifecycle is fully scoped
    # to this fetch — we `stop` it in the `after` clause.
    case GenServer.start(Browser, browser_opts, []) do
      {:ok, browser} ->
        try do
          run_one_shot(browser, url, opts)
        after
          Browser.stop(browser)
        end

      {:error, {:init_failed, %Error{} = e}} ->
        {:error, e}

      {:error, other} ->
        {:error,
         Error.exception(reason: :runtime, message: "browser failed to start: #{inspect(other)}")}
    end
  end

  defp run_one_shot(browser, url, opts) do
    with {:ok, page} <- navigate_with(browser, url, opts),
         {:ok, page} <- maybe_wait_for(browser, opts, page),
         {:ok, body} <- content(browser),
         {:ok, evaluated} <- maybe_evaluate(browser, opts[:evaluate]),
         {:ok, extracted} <- maybe_extract(browser, opts[:extract]),
         {:ok, screenshot} <- maybe_screenshot(browser, opts[:screenshot]) do
      {:ok,
       %Result{
         status: :ok,
         url: page.url,
         title: page.title,
         body: body,
         evaluated: evaluated,
         extracted: extracted,
         screenshot: screenshot
       }}
    else
      {:error, %Error{} = e} ->
        {:error, e}
    end
  end

  defp navigate_with(browser, url, opts) do
    Browser.call(browser, {:navigate, url, opts[:timeout]}, opts[:timeout])
  end

  defp maybe_wait_for(browser, opts, page) do
    case opts[:wait_for] do
      nil ->
        {:ok, page}

      selector when is_binary(selector) ->
        timeout = opts[:wait_timeout]

        case Browser.call(browser, {:wait_for, selector, timeout}, timeout) do
          {:ok, _} -> {:ok, page}
          {:error, _} = err -> err
        end
    end
  end

  defp maybe_evaluate(_browser, nil), do: {:ok, nil}
  defp maybe_evaluate(browser, expr), do: Browser.call(browser, {:evaluate, expr})

  defp maybe_extract(_browser, nil), do: {:ok, nil}

  defp maybe_extract(browser, selectors) when is_list(selectors) do
    Enum.reduce_while(selectors, {:ok, %{}}, fn {key, selector}, {:ok, acc} ->
      case Browser.call(browser, {:get_texts, selector}) do
        {:ok, values} ->
          value =
            case values do
              [single] -> single
              many -> many
            end

          {:cont, {:ok, Map.put(acc, key, value)}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp maybe_screenshot(_browser, false), do: {:ok, nil}
  defp maybe_screenshot(browser, true), do: screenshot(browser, format: :png)
  defp maybe_screenshot(browser, format) when format in [:png, :jpeg], do: screenshot(browser, format: format)

  # ── long-lived-browser API ────────────────────────────────────────────────

  @doc """
  Start a long-lived browser linked to the caller.

  See `Rover.Browser.start_link/1` for the full list of options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts \\ []), to: Browser

  @doc """
  Gracefully stop a browser.
  """
  @spec stop(GenServer.server(), timeout()) :: :ok
  defdelegate stop(browser, timeout \\ 5_000), to: Browser

  @doc "Navigate to a URL and wait for load."
  @spec navigate(GenServer.server(), String.t(), keyword()) ::
          {:ok, %{url: String.t(), title: String.t()}} | {:error, Error.t()}
  def navigate(browser, url, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    Browser.call(browser, {:navigate, url, timeout}, timeout)
  end

  @doc "Return the document URL after redirects."
  @spec current_url(GenServer.server()) :: {:ok, String.t()} | {:error, Error.t()}
  def current_url(browser), do: Browser.call(browser, :current_url)

  @doc "Return the rendered `outerHTML` of the document element."
  @spec content(GenServer.server()) :: {:ok, String.t()} | {:error, Error.t()}
  def content(browser), do: Browser.call(browser, :content)

  @doc "Return `document.title`."
  @spec title(GenServer.server()) :: {:ok, String.t()} | {:error, Error.t()}
  def title(browser), do: Browser.call(browser, :title)

  @doc """
  Block until a CSS selector matches at least one element, or `:timeout` ms elapse.
  """
  @spec wait_for(GenServer.server(), String.t(), keyword()) ::
          {:ok, :ok} | {:error, Error.t()}
  def wait_for(browser, selector, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    Browser.call(browser, {:wait_for, selector, timeout}, timeout)
  end

  @doc """
  Evaluate a JavaScript expression in the page context and return its value.

  Simple values (string/number/boolean/null) round-trip as Elixir terms.
  Arrays and objects become lists and maps.
  """
  @spec evaluate(GenServer.server(), String.t()) :: {:ok, term()} | {:error, Error.t()}
  def evaluate(browser, expression), do: Browser.call(browser, {:evaluate, expression})

  @doc "Return the first matching element's `innerText`."
  @spec get_text(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_text(browser, selector), do: Browser.call(browser, {:get_text, selector})

  @doc "Return every matching element's `innerText` as a list."
  @spec get_texts(GenServer.server(), String.t()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def get_texts(browser, selector), do: Browser.call(browser, {:get_texts, selector})

  @doc "Return the value of the named attribute on the first match."
  @spec get_attribute(GenServer.server(), String.t(), String.t()) ::
          {:ok, term()} | {:error, Error.t()}
  def get_attribute(browser, selector, name),
    do: Browser.call(browser, {:get_attribute, selector, name})

  @doc "Click the element (center of its bounding box)."
  @spec click(GenServer.server(), String.t()) :: {:ok, :ok} | {:error, Error.t()}
  def click(browser, selector), do: Browser.call(browser, {:click, selector})

  @doc "Fill an input/textarea with `value` and dispatch input/change events."
  @spec fill(GenServer.server(), String.t(), String.t()) :: {:ok, :ok} | {:error, Error.t()}
  def fill(browser, selector, value), do: Browser.call(browser, {:fill, selector, value})

  @doc "Hover the mouse cursor over the element."
  @spec hover(GenServer.server(), String.t()) :: {:ok, :ok} | {:error, Error.t()}
  def hover(browser, selector), do: Browser.call(browser, {:hover, selector})

  @doc "Select an option in a `<select>` by its value."
  @spec select_option(GenServer.server(), String.t(), String.t()) ::
          {:ok, :ok} | {:error, Error.t()}
  def select_option(browser, selector, value),
    do: Browser.call(browser, {:select_option, selector, value})

  @screenshot_schema [
    format: [type: {:in, [:png, :jpeg]}, default: :png],
    quality: [type: :integer, default: 85]
  ]

  @doc """
  Capture a screenshot of the page.

  Options:

    * `:format` — `:png` (default) or `:jpeg`.
    * `:quality` — JPEG quality 1..100, ignored for PNG. Default: 85.
  """
  @spec screenshot(GenServer.server(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def screenshot(browser, opts \\ []) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @screenshot_schema) do
      Browser.call(browser, {:screenshot, opts[:format], opts[:quality]})
    else
      {:error, %NimbleOptions.ValidationError{message: m}} ->
        {:error, Error.exception(reason: :invalid_argument, message: m)}
    end
  end

  @doc """
  Return every cookie visible at the current document URL.
  """
  @spec get_cookies(GenServer.server()) :: {:ok, [map()]} | {:error, Error.t()}
  def get_cookies(browser), do: Browser.call(browser, :get_cookies)

  @doc """
  Parse and set a cookie for the current document URL.

  `cookie` is a Set-Cookie header value, e.g. `"sid=abc; path=/; HttpOnly"`.
  """
  @spec set_cookie(GenServer.server(), String.t()) :: {:ok, :ok} | {:error, Error.t()}
  def set_cookie(browser, cookie), do: Browser.call(browser, {:set_cookie, cookie})

  @doc "Clear all cookies."
  @spec clear_cookies(GenServer.server()) :: {:ok, :ok} | {:error, Error.t()}
  def clear_cookies(browser), do: Browser.call(browser, :clear_cookies)
end
