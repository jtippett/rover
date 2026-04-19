# Rover

Drive the [Servo](https://servo.org) web engine from Elixir.

Rover runs each browser as its own OS process, isolated from the BEAM and from
other browsers. That gives you per-instance proxy config, independent cookie
jars, and crash containment — if a page crashes the renderer, your VM keeps
running.

The API is modelled after [`Req`](https://hexdocs.pm/req): small, composable,
and sensible by default.

> **Status:** 0.1 — proof-of-concept. The Rust runtime embeds Servo via path
> dependency during development; precompiled binaries via GitHub Releases are
> planned for the first tagged release.

## Why Rover?

If you just want the bytes of an HTTP response, use `Req`. Rover is for the
cases where `Req` is not enough:

- **JS-rendered pages** — content only exists after `<script>` tags execute.
- **Per-instance proxies** — route different browsers through different
  egresses (customer machines, regional proxies, etc.).
- **Input automation** — click, fill, submit forms, then read the result.
- **Visual capture** — screenshots for verification or diffing.

## Installation

Add `:rover` to your deps in `mix.exs`:

```elixir
def deps do
  [
    {:rover, "~> 0.1"}
  ]
end
```

Rover ships a companion Rust binary, `rover_runtime`, that embeds Servo. For
0.1 you build it from source (precompiled distribution comes next):

```shell
mix deps.get
mix rover.build
```

Servo's first compile is long (10–30 min on an M-series Mac; a cold
SpiderMonkey build is the tall pole). Subsequent builds are fast thanks to
cargo's incremental cache. The binary is discovered automatically, but you can
override with:

```shell
ROVER_RUNTIME_BIN=/absolute/path/to/rover_runtime iex -S mix
```

## Quick start

```elixir
{:ok, result} = Rover.fetch("https://example.com")
result.body   # rendered HTML
result.title  # document.title
result.url    # final URL after redirects
```

---

# Usage guide

Rover has two ways in: the **one-shot** `Rover.fetch/2` for single-page work,
and the **long-lived browser** (`Rover.start_link/1`) for multi-step
automation. Pick whichever matches the shape of your task — not both at once.

## One-shot: `Rover.fetch/2`

`fetch/2` spins up a browser, does the work, tears it down. Use it for
stateless scraping where you don't need to carry cookies or navigate between
pages.

```elixir
{:ok, result} = Rover.fetch("https://example.com")

result.status    # :ok
result.url       # "https://example.com/"  (after redirects)
result.title     # "Example Domain"
result.body      # "<!doctype html>…"  (rendered HTML)
```

### Waiting for JS-rendered content

Many sites don't fully populate the DOM until some script has run. Pass
`:wait_for` with a CSS selector that only exists *after* the page is ready:

```elixir
{:ok, result} =
  Rover.fetch("https://movies.example/now-showing",
    wait_for: ".movie-list",      # poll until this appears
    wait_timeout: 15_000           # then give up
  )
```

Without `:wait_for`, Rover returns as soon as `document.readyState == complete`
— which is typically too early for SPAs that fetch data after first paint.

### Evaluating JavaScript

`evaluate` runs an expression in the page and round-trips the result as an
Elixir term:

```elixir
{:ok, result} =
  Rover.fetch("https://shop.example/product/42",
    evaluate: "JSON.parse(document.querySelector('#product-data').textContent)"
  )

result.evaluated
# %{
#   "price" => 4999,
#   "currency" => "EUR",
#   "in_stock" => true,
#   "tags" => ["leather", "handmade"]
# }
```

Strings, numbers, booleans, `null`, arrays, and objects all convert cleanly.
Functions, DOM nodes, and promises don't — wrap them in something JSON-able
first.

### Extracting multiple selectors

`extract` is a convenience for grabbing text from several selectors in one
trip:

```elixir
{:ok, result} =
  Rover.fetch("https://news.example/",
    wait_for: "article",
    extract: [
      headline: "h1.lead",
      subheads: "h2.section-header",
      bylines: ".author"
    ]
  )

result.extracted
# %{
#   headline: "Markets surge on surprise rate cut",
#   subheads: ["Global reaction", "Sector breakdown"],
#   bylines: ["J. Cooper", "R. Singh"]
# }
```

Single-match selectors give a string; multi-match selectors give a list.

### Screenshot

```elixir
{:ok, result} =
  Rover.fetch("https://dashboard.example/metrics",
    wait_for: ".chart-loaded",
    screenshot: :png
  )

File.write!("dashboard.png", result.screenshot)
```

`screenshot: :png` is the default; pass `:jpeg` for smaller files. JPEG
quality is configurable on the long-lived browser only (`Rover.screenshot/2`).

### Routing through a proxy

```elixir
{:ok, result} =
  Rover.fetch("https://ipinfo.io/json",
    proxy: "http://eu.proxy.example:8080",
    evaluate: "JSON.parse(document.body.innerText)"
  )

result.evaluated["country"]  # "DE"
```

The proxy URI accepts `http://user:pass@host:port` for basic auth. It's baked
into the browser at startup and applies to every request, including CONNECTs
for HTTPS. For per-request routing, use multiple browsers (see below).

## Long-lived browser: `Rover.start_link/1`

When you need to log in, then click around, then scrape — use a long-lived
browser. Each browser keeps its cookies, auth state, and page position across
commands.

```elixir
{:ok, browser} = Rover.start_link(proxy: "http://proxy:8080")

try do
  :ok = Rover.navigate(browser, "https://app.example/login")
  :ok = Rover.fill(browser, "#email", "user@example.com")
  :ok = Rover.fill(browser, "#password", "hunter2")
  :ok = Rover.click(browser, "button[type=submit]")
  :ok = Rover.wait_for(browser, ".dashboard")

  {:ok, html} = Rover.content(browser)
  # …do stuff with html…
after
  Rover.stop(browser)
end
```

### Putting the browser under supervision

`Rover.Browser` is a plain GenServer — add it to your supervision tree and
let OTP manage restarts:

```elixir
children = [
  {Rover.Browser, name: MyApp.EUBrowser, proxy: "http://eu-proxy:8080"},
  {Rover.Browser, name: MyApp.USBrowser, proxy: "http://us-proxy:8080"}
]

Supervisor.start_link(children, strategy: :one_for_one)

# Later, anywhere:
Rover.navigate(MyApp.EUBrowser, "https://site.example/eu-only")
```

If the Servo subprocess crashes, the Port dies, the `Rover.Browser` GenServer
exits with `{:port_died, _}`, and your supervisor restarts it — fresh state,
same proxy config. The BEAM never sees the failure.

### Per-instance routing (the point of Rover)

Two browsers, two egresses:

```elixir
{:ok, eu} = Rover.start_link(proxy: "http://eu-egress:8080")
{:ok, us} = Rover.start_link(proxy: "http://us-egress:8080")

locations =
  [eu, us]
  |> Task.async_stream(fn browser ->
    {:ok, _page} = Rover.navigate(browser, "https://ipinfo.io/json")
    {:ok, json}  = Rover.get_text(browser, "pre")
    Jason.decode!(json)
  end)
  |> Enum.map(fn {:ok, v} -> v end)

# locations = [%{"country" => "DE", …}, %{"country" => "US", …}]
```

Because each browser is its own OS process, the two flows never share cookies,
connection pools, or DNS cache. No amount of `Set-Cookie` from one browser
leaks into the other.

### Filling forms with real input

`fill` and `click` dispatch the same events a user's keyboard and mouse would.
That matters for frontends that listen on `input` / `change` / `submit`:

```elixir
:ok = Rover.fill(browser, "#search", "elixir")
:ok = Rover.wait_for(browser, ".autocomplete-ready")
:ok = Rover.click(browser, ".suggestion:nth-child(1)")
```

`fill` is safe for `<input>`, `<textarea>`, and `contenteditable` regions.
`select_option` works on `<select>`:

```elixir
:ok = Rover.select_option(browser, "#country", "IE")
```

### Cookies

Rover talks to Servo's `SiteDataManager` directly — no `document.cookie`
round-trips. `HttpOnly` cookies are visible.

```elixir
{:ok, _} = Rover.navigate(browser, "https://app.example/")
{:ok, cookies} = Rover.get_cookies(browser)

session_cookie = Enum.find(cookies, fn c -> c["name"] == "sid" end)

# Set a cookie manually (e.g., to skip a login screen)
:ok = Rover.set_cookie(browser, "sid=abc123; path=/; Secure; HttpOnly")

# Nuke the jar
:ok = Rover.clear_cookies(browser)
```

## Error handling

`Rover.fetch/2` and the long-lived-browser calls never raise. They return
`{:ok, result} | {:error, %Rover.Error{}}`. Pattern match on `:reason` to
dispatch recovery:

```elixir
case Rover.fetch(url, proxy: proxy_uri) do
  {:ok, result} ->
    handle(result)

  {:error, %Rover.Error{reason: :timeout}} ->
    Logger.warning("slow page: #{url}")
    :skip

  {:error, %Rover.Error{reason: :proxy}} ->
    retry_direct(url)

  {:error, %Rover.Error{reason: :selector_timeout, message: m}} ->
    Logger.error("page never rendered: #{m}")
    :skip
end
```

Reasons: `:timeout`, `:navigation`, `:selector_not_found`, `:selector_timeout`,
`:evaluation`, `:proxy`, `:invalid_argument`, `:runtime`, `:shutdown`,
`:port_died`.

## Capability summary

| Operation       | Elixir                                          | Notes                                            |
|-----------------|-------------------------------------------------|--------------------------------------------------|
| Navigate        | `Rover.navigate(b, url)`                        | Waits for `LoadStatus::Complete`.               |
| Content         | `Rover.content(b)`                              | Rendered `outerHTML`.                           |
| Title           | `Rover.title(b)`                                |                                                  |
| Wait            | `Rover.wait_for(b, "sel", timeout: 5_000)`      | Polls via `querySelector`.                      |
| Evaluate JS     | `Rover.evaluate(b, "1 + 2")`                    | Round-trips strings, numbers, arrays, maps.     |
| Extract text    | `Rover.get_text(b, "h1")`                       | Also `get_texts`, `get_attribute`.              |
| Click / fill    | `Rover.click(b, "sel")`                         | Dispatches real mouse events at element centre. |
| Hover / select  | `Rover.hover(b, ".tip")`                        | `select_option` fires change events.            |
| Screenshot      | `Rover.screenshot(b, format: :png)`             | PNG or JPEG.                                    |
| Cookies         | `Rover.get_cookies(b) / set_cookie / clear_*`   | Direct via Servo's `SiteDataManager`.           |

---

# Architecture

## The shape

```
┌─ BEAM ──────────────────────────────────────────────────────────┐
│                                                                 │
│  Your Supervisor                                                │
│      │                                                          │
│  Rover.Browser (GenServer)                                      │
│      │ owns a Port with `packet: 4`                             │
│      │   length-prefixed MessagePack frames                     │
└──────┼──────────────────────────────────────────────────────────┘
       │ stdin/stdout                                             
       │ stderr → Logger                                          
┌──────▼──────────────────────────────────────────────────────────┐
│  rover_runtime (Rust, one OS process per browser)               │
│    main thread: read frame → dispatch → write reply             │
│    owns: Servo instance + one WebView + SoftwareRenderingContext│
└─────────────────────────────────────────────────────────────────┘
```

Every browser is:

1. An Elixir `Rover.Browser` GenServer under your supervision tree.
2. A dedicated `rover_runtime` OS subprocess, spawned via `Port` with
   `packet: 4` framing.
3. Inside that subprocess: one `Servo` instance, one `WebView`, one
   `SoftwareRenderingContext`.

Elixir and Rust speak length-prefixed MessagePack over stdin/stdout. Stderr
is not merged — it goes to the BEAM's stderr for log capture.

## Why a separate OS process per browser?

This was the main design decision, and it was the *second* architecture we
tried. The short version: **Servo has process-global state that makes
multiple Servo instances in one address space either broken or dangerous**,
and the cleanest way to isolate it is the same way Firefox and Chrome do —
put each browser in its own process.

### What we tried first: in-process NIF, many Servos

The obvious Elixir design is a Rustler NIF: one BEAM process, multiple
`Servo` instances, each with its own proxy config. That's how
[BrowseServo](https://github.com/gentility-io/browse_servo) ships (though
BrowseServo uses a singleton engine and doesn't support per-instance
proxies — which is exactly the gap we were trying to fix).

Looking at Servo's source, the first problem surfaces immediately. In
`components/servo/servo.rs`:

```rust
fn new(builder: ServoBuilder) -> Self {
    // Global configuration options, parsed from the command line.
    let opts = builder.opts.map(|opts| *opts);
    opts::initialize_options(opts.unwrap_or_default());
    …
}
```

And `components/config/opts.rs`:

```rust
pub fn initialize_options(opts: Opts) {
    OPTIONS.set(opts).expect("Already initialized");
}
```

`OnceLock::set().expect(...)` panics on the second call. **Creating a
second `Servo` in the same process panics** — so multi-Servo-in-one-NIF is
not possible without patching Servo.

A one-line fix (swap `.set().expect()` for `.get_or_init()`) gets past that,
but the deeper audit uncovered more:

- `script::init()` (called unconditionally from `Servo::new()`) initialises
  SpiderMonkey: `DisableJitBackend`, `RegisterProxyHandlers`,
  `InitAllStatics`, `InitializeMemoryReporter`. SpiderMonkey is
  **designed to init exactly once per process**. Running it twice isn't
  supported and would wander into undefined behaviour inside the JS engine.
- `servo_config::prefs::set()` writes to a global `RwLock<Preferences>`.
  The `ProxyConnector` reads `pref!(network_http_proxy_uri)` once, at
  `HttpState` construction. `HttpState` is shared across every WebView of a
  Servo instance, so proxy config is *per-Servo-instance* at best even if
  we could create multiple Servos.

So Option A (patch Servo, make it multi-tenant in one process) turned into
"patch SpiderMonkey init semantics and hope class-vtable re-registration
is harmless." A change where the failure mode is silent heap corruption.

### The pivot: one process per browser

Option B — what Rover actually does — is to treat each Servo as its own OS
process. The Elixir side spawns `rover_runtime` via `Port`; the Rust side
calls `Servo::new()` exactly once in `main()`, before entering the IPC
loop. Every constraint Servo has about "once per process" is automatically
satisfied, because every browser *is* a process.

That gives us:

- **Isolation by construction.** `OPTIONS`, `Preferences`,
  SpiderMonkey statics, the cookie jar, the DNS cache, connection pools —
  all live inside one process. Nothing leaks between browsers.
- **Per-instance proxy.** Set `Preferences.network_http_proxy_uri` in
  `main()`, build the `Servo`, you're done. No shared state to worry about.
- **Crash containment.** A renderer segfault takes down its OS process.
  The Port reports the exit status, `Rover.Browser` raises a typed
  `:port_died`, the supervisor restarts it. The BEAM never faults.
- **Unmodified upstream Servo.** Rover depends on Servo as a regular Rust
  path dep with no patches. We can `cargo update` when Servo releases a new
  version and pick up fixes without re-doing a fork.

The cost is an IPC boundary. Every command is a `Port.command` (Elixir) →
stdin write (Rust) → `rmp-serde` decode → dispatch → reply write →
`Msgpax.unpack!` (Elixir). That adds hundreds of microseconds per command.
On a browser that takes hundreds of *milliseconds* to paint a page, this
doesn't matter. If it ever does, the architecture admits an in-process
design later without breaking the public API — but we'd need SpiderMonkey
to gain multi-tenant support first, and that's not our fight.

### Why MessagePack (not JSON, not ETF)

The wire format only needs to carry structured values, some strings, and
the occasional large binary (screenshots). Three options:

- **JSON.** Universal but ~1.5× larger, slow to parse at size, and
  represents binaries as Base64 — which doubles screenshot payloads again.
- **Erlang External Term Format (ETF).** Zero parsing on the Elixir side,
  but pulling it into Rust means vendoring an ETF encoder. Extra surface
  area for little gain.
- **MessagePack.** Compact, fast, first-class binary type, mature libraries
  on both sides (`rmp-serde` in Rust, `Msgpax` in Elixir). `Port` handles
  framing via `packet: 4`, so we only ever deal with payload bytes.

MessagePack won because the framing problem is already solved by `Port`, and
the binary type means screenshots aren't paying a Base64 tax.

### Why not a pool of browsers per proxy from day one?

The plan calls for `Rover.Pool` — a `NimblePool` keyed by proxy URI. It's
deferred because:

1. The interesting problem is proving isolation works. A pool is scaffolding
   on top. Getting the per-instance Servo story right first means the pool
   has a solid base.
2. Cheap to add later. `NimblePool` already knows how to manage long-lived
   workers; wrapping `Rover.Browser` is ~50 lines of Elixir.

For 0.1, start one `Rover.Browser` per proxy config and reuse it, or use
`Rover.fetch/2` and pay the startup cost each time (~100–500ms on a warm
binary).

## Why Servo, not Chromium / WebKit / Firefox?

Brief answer: **it's the only mature-ish browser engine that builds as a
library.** Chromium has CEF but it's a monster; WebKit requires GObject/GTK
or Objective-C depending on where you build; Gecko has no embedder story.
Servo was designed from day one to be embeddable, ships as a regular Rust
crate, and its API surface (`Servo`, `WebView`, `evaluate_javascript`,
`take_screenshot`, `SiteDataManager`) maps naturally onto what a browser
automation library wants.

It also happens to be written in Rust, which means the path from Servo APIs
to BEAM-safe values goes through `serde` and `rmp-serde`. No unsafe FFI
boundary to worry about; no "what happens when Rust panics" question (the
subprocess exits, we report it as `:port_died`, the supervisor deals).

The downside is Servo's browser feature set isn't Chrome's. Several web
platform features are incomplete — Web Components is the big one. For the
use cases Rover targets (scraping server-rendered sites, SPAs with standard
React/Vue output, filling forms) this hasn't been a problem. For a
pixel-perfect Chrome replacement, use a headless Chrome driver.

## Public API surface

```
Rover
├─ fetch/2                       ─ one-shot
├─ start_link/1                  ─ long-lived (delegates to Rover.Browser)
├─ stop/2
├─ navigate/3, current_url/1, content/1, title/1
├─ wait_for/3
├─ evaluate/2, get_text/2, get_texts/2, get_attribute/3
├─ click/2, fill/3, hover/2, select_option/3
├─ screenshot/2
└─ get_cookies/1, set_cookie/2, clear_cookies/1

Rover.Browser                    ─ GenServer
Rover.Result                     ─ struct returned by fetch/2
Rover.Error                      ─ exception with typed :reason atoms
Rover.Protocol                   ─ internal — wire format (don't depend on it)
Rover.Runtime                    ─ internal — binary path resolution
```

## Not yet

- `Rover.Pool` — recyclable browsers keyed by proxy.
- Precompiled runtime distribution via GitHub Releases + checksum
  verification.
- `[:rover, :fetch, :*]` telemetry events.
- Download capture / file interception.
- Multiple WebViews per engine — deliberately out of scope. One browser =
  one page. For concurrent pages, start multiple browsers.

## License

MPL-2.0 — matches Servo.
