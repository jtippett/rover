defmodule Rover.Test.Server do
  @moduledoc false
  # Tiny Bandit-backed HTTP server used by integration tests.
  #
  # Routes served:
  #
  #   GET  /plain       — static "Hello, Rover."
  #   GET  /rendered    — HTML that mutates its own DOM via inline JS, so a
  #                        headless fetch would *not* see the mutated content;
  #                        ExServo, via Servo, does.
  #   GET  /form        — page with a fillable form + submit
  #   POST /form-target — echoes the submitted form values in HTML
  #   GET  /slow        — hangs for `?ms=N` milliseconds before replying
  #   GET  /cookie-jar  — responds with a Set-Cookie, page shows document.cookie
  #
  # Returns `{:ok, port}`.

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"])
  plug(:dispatch)

  def start_link(opts \\ []) do
    with {:ok, sup} <- Bandit.start_link(plug: __MODULE__, port: Keyword.get(opts, :port, 0)),
         {:ok, {_ip, port}} <- ThousandIsland.listener_info(sup) do
      {:ok, %{sup: sup, port: port}}
    end
  end

  def stop(%{sup: sup}) do
    # Bandit's graceful shutdown can take a beat; fall back to a hard stop if
    # the supervisor is unresponsive.
    spawn(fn ->
      try do
        Supervisor.stop(sup, :normal, 500)
      catch
        :exit, _ -> Process.exit(sup, :kill)
      end
    end)

    :ok
  end

  @plain """
  <!doctype html>
  <html><head><title>Plain</title></head>
  <body><h1 class="greeting">Hello, Rover.</h1></body></html>
  """

  get "/plain" do
    put_html(conn, @plain)
  end

  @rendered """
  <!doctype html>
  <html><head><title>Pre-render</title></head>
  <body>
    <div id="root">Loading…</div>
    <ul class="items">
      <li>One</li><li>Two</li><li>Three</li>
    </ul>
    <script>
      document.title = "Rendered";
      document.getElementById("root").textContent = "Ready";
      const flag = document.createElement("div");
      flag.id = "js-ready";
      flag.textContent = "js ran";
      document.body.appendChild(flag);
    </script>
  </body></html>
  """

  get "/rendered" do
    put_html(conn, @rendered)
  end

  @form """
  <!doctype html>
  <html><body>
    <form action="/form-target" method="POST">
      <input name="email" id="email" type="email" />
      <input name="password" id="password" type="password" />
      <select name="country" id="country">
        <option value="IE">Ireland</option>
        <option value="US">United States</option>
      </select>
      <button type="submit" id="submit">Sign in</button>
    </form>
    <div id="greeting"></div>
  </body></html>
  """

  get "/form" do
    put_html(conn, @form)
  end

  post "/form-target" do
    email = Map.get(conn.params, "email", "")
    country = Map.get(conn.params, "country", "")

    put_html(
      conn,
      """
      <!doctype html><html><body>
        <div id="echo-email">#{Plug.HTML.html_escape(email)}</div>
        <div id="echo-country">#{Plug.HTML.html_escape(country)}</div>
      </body></html>
      """
    )
  end

  get "/slow" do
    ms =
      conn
      |> Plug.Conn.fetch_query_params()
      |> Map.get(:query_params, %{})
      |> Map.get("ms", "0")
      |> String.to_integer()

    Process.sleep(ms)
    put_html(conn, "<p>awake</p>")
  end

  get "/cookie-jar" do
    conn
    |> Plug.Conn.put_resp_cookie("rover_tracker", "baked", http_only: true)
    |> put_html("<p id=\"c\"><script>document.getElementById('c').textContent = document.cookie</script></p>")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp put_html(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html; charset=utf-8")
    |> Plug.Conn.send_resp(200, body)
  end
end
