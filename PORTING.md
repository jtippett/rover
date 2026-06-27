# Rover Porting Playbook

How to extend Rover's surface over Servo without regressing the things that are
hard to get right. This is the methodology; the API itself lives in `lib/rover/`
and the README.

## 0. The shape of the thing

```
Elixir (Rover, app: :rover)            native/rover_runtime (Rust bin)        Servo
  Rover.Browser GenServer  ──Port──▶   main(): one Servo + one WebView   ──▶  engine
  length-prefixed MessagePack          read frame → dispatch → reply           (pinned rev)
```

Rover is **not a NIF binding**. It drives Servo out-of-process: `rover_runtime` is
a standalone executable that embeds Servo and speaks length-prefixed MessagePack
over stdio. Elixir spawns **one OS process per browser**. The "map" of Servo's API
lives in `rover_runtime/src/` (Rust); the Elixir side is a thin driver over the
wire protocol.

## 1. Lessons to honor

### The precompiled-binary release dance (the part everyone gets wrong)
- The `:rover_download` Mix compiler downloads a prebuilt `rover_runtime` whose
  sha256 must be in `checksum-rover_runtime.exs`. **That file is regenerated
  *after* a release exists.** Full ordering in
  [`UPDATE_PROCEDURE.md`](UPDATE_PROCEDURE.md). The trap:
  1. tag `vX.Y.Z` → `release.yml` builds the binaries and creates the GitHub release,
  2. **then** `mix rover.runtime.download --all --print` downloads them and writes
     the checksum file,
  3. publish to Hex (the `publish` job does it from CI, gated by the `hex`
     environment) — the package tarball carries the freshly-generated checksums.
- No NIF ABI version in the artifact names (it's an executable, not a NIF), so —
  unlike a `rustler_precompiled` library — there's no per-OTP/per-NIF-version
  matrix. One binary per target triple, loaded by any OTP.
- When building/compiling the library *itself* (dev, CI, the publish job), set
  `ROVER_BUILD=1` so `:rover_download` skips the download and you use the local
  `cargo` build (or skip the binary entirely when only publishing).

### Pin Servo to an exact revision, never a moving branch
- `native/rover_runtime/Cargo.toml` pins Servo by git rev (a path dep against a
  checkout at that rev). Bump deliberately via the update procedure — three places
  must move together (Cargo.toml comment, `release.yml` `ref:`, `fetch-servo.sh`).
- `Cargo.lock` is committed; it pins Servo's full transitive tree for reproducible
  CI and consumer builds.

### CI gates that catch the common breakage
- `mix format --check-formatted`, `rustfmt --edition 2024 --check
  native/rover_runtime/src/*.rs` (invoked directly so it doesn't drag in Servo's
  dep graph just to format-check), `mix compile --warnings-as-errors`, `mix test
  --exclude integration`.
- CI runs the Elixir suite with `ROVER_BUILD=1` against a locally-built (or
  stubbed) runtime, not a downloaded one.

### Docs are part of "done"
- Every new public function gets a moduledoc + `@spec` + a test. Every new
  capability gets a README "Capability summary" row and a `CHANGELOG.md`
  `[Unreleased]` entry. Doc drift is the easiest thing to forget.

### The working loop
Per capability: **TDD** (write the failing test first — `ROVER_BUILD=1 mix test`)
→ implement (Rust handler in `rover_runtime` + Elixir API, marshal-only over the
wire) → **full gate** (`mix test`, `mix format --check-formatted`, rustfmt,
`mix compile --warnings-as-errors`) → dispatch the `superpowers:code-reviewer`
subagent against the diff → fold fixes → commit → push → watch CI green. Each
capability also earns a README row and a CHANGELOG entry.

## 2. What's genuinely different about Servo (the crux)

### One process per browser is forced, not a preference
Servo has **process-global state that makes multiple `Servo` instances in one
address space broken or dangerous** — re-verified against upstream `main`:
- `opts::initialize_options` → `OPTIONS.set(opts).expect("Already initialized")`
  panics on the second `Servo::new()`.
- `script::init()` re-registers SpiderMonkey global vtables/statics with no
  re-entry guard; SpiderMonkey is designed to initialize once per process.
- `servo_config::prefs` is a process-global `RwLock<Preferences>` — the HTTP proxy
  URI is read from it, so proxy config is per-process at best.

So per-instance proxies (Rover's reason to exist) require **process isolation**.
Don't "simplify" Rover into a singleton in-process NIF without first confirming
upstream Servo + SpiderMonkey gained multi-tenant support — they have not.

### Map the engine in Rust; keep Elixir a thin driver
New capability = a new MessagePack request/response + a Rust handler that calls
Servo, **not** behavior reimplemented in Elixir. The Elixir side validates inputs
(`nimble_options`), marshals, and shapes errors (`Rover.Error`).

### Servo is a moving target with no ABI
There is no stable embedding API and no prebuilt `libservo`. Expect API drift on
every Servo bump (builder signatures, `WebView`, `evaluate_javascript`,
`take_screenshot`, `SiteDataManager`) and expect to **build Servo from source** in
CI — there is nothing to download and bundle.

## 3. Definition of done (per capability and overall)

- Failing test written first, then passing; full gate green; CI green.
- Public API documented (`@doc`, `@spec`), README row added, CHANGELOG updated.
- Reviewed (`superpowers:code-reviewer`) and fixes folded.
- No behavior reimplemented Elixir-side that belongs in the Servo map.
- Release verified by a clean install on a toolchain-free machine
  (see UPDATE_PROCEDURE.md).
