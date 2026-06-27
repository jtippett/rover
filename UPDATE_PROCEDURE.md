# Rover Update & Release Procedure

Two things drift over time and need a deliberate procedure:

1. **Servo** — the web engine, pinned by git revision in
   `native/rover_runtime/Cargo.toml` (a path dep), the `ref:` in
   `.github/workflows/release.yml`, and the default in `scripts/fetch-servo.sh`.
2. **rover_runtime's own crate deps** — pinned by `native/rover_runtime/Cargo.lock`
   (committed; the lock pins Servo's full transitive tree for reproducible builds).

And one thing must happen in a **specific order** every release: generating the
`checksum-rover_runtime.exs` file from the released binaries. That's the part
everyone gets wrong; it's last.

> **Why this differs from a normal NIF library.** Rover ships a standalone *port
> binary* (`rover_runtime`), not a NIF, so there's no `rustler_precompiled`. The
> `:rover_download` Mix compiler is the port-binary equivalent: it downloads the
> prebuilt binary from the GitHub release and verifies it against the checksum
> file. Servo also has no prebuilt embeddable library (unlike pdfium's bblanchon
> binaries), so the binary is **built from source in CI** — there's nothing to
> "download and bundle," only our own compiled artifact to ship.

---

## Part A — Bumping the pinned Servo revision

Servo is a fast-moving git project with no embedding ABI stability, so we pin an
exact revision and bump it deliberately.

1. Pick a new revision from https://github.com/servo/servo (a commit that builds;
   prefer one CI is green on).
2. **Update all three places together** (they must match, or CI clones a different
   Servo than the path dep expects):
   - `native/rover_runtime/Cargo.toml` — the `Pinned Servo revision` comment **and**
     keep the `servo = { path = ... }` dep pointing at `../../servo_rust`.
   - `.github/workflows/release.yml` — the `ref:` under "Check out Servo (pinned)".
   - `scripts/fetch-servo.sh` — the default `REV`.
   - `justfile` — the `servo` recipe's default `rev`.
3. Re-pin the lockfile and rebuild locally:
   ```bash
   just servo                       # clone/checkout Servo at the new rev
   cd native/rover_runtime && cargo update && cargo build --release
   cd ../.. && just test            # ROVER_BUILD=1 mix test
   ```
4. Fix any API drift in `native/rover_runtime/src/*.rs` (most likely: `Servo` /
   `WebView` builder changes, `evaluate_javascript`, `take_screenshot`,
   `SiteDataManager`). **Map** the new API — don't reimplement engine behavior
   Elixir-side.
5. Commit `Cargo.toml`, `Cargo.lock`, the workflow, and the scripts together.

> **Security:** if upstream Servo lands a fix for a parsing/sandbox/JS CVE, bump
> promptly.

---

## Part B — Cutting a Rover release (order matters)

Use `just release` (`scripts/release.exs`) for steps 1–2; the rest is the workflow
plus the checksum generation, which CI does for you.

1. **Bump the version.** `just release` shows current vs. published, asks
   patch/minor/major, rolls the `CHANGELOG.md` `[Unreleased]` section into a dated
   heading, then (on confirm) commits, tags `vX.Y.Z`, and pushes — which triggers
   `release.yml`.
   - Semver is against **Rover's** Elixir API, not Servo's. Big additive features
     are minor `0.x` bumps.
   - Tags with a dash (`v0.2.0-rc.0`) are published as GitHub **pre-releases**
     automatically.
2. **Wait for `release.yml`'s build matrix to finish.** Confirm the GitHub release
   has **one tarball per target** (3: linux x64, linux arm64, darwin arm64), each
   with a `.sha256` sidecar.
3. **The `publish` job generates the checksum file and publishes to Hex.** It is
   **gated by the `hex` environment** — GitHub pauses for a required-reviewer
   approval so you can eyeball the release first. On approval it:
   - runs `mix rover.runtime.download --all --print`, which downloads the released
     tarballs, hashes them, and writes `checksum-rover_runtime.exs`;
   - runs `mix hex.publish` so the Hex package carries that checksum file.
   - `ROVER_BUILD=1` is set so the publish-time compile skips the binary download
     entirely (the package ships sources + checksum, not the binary).
4. **(Optional) commit the checksum file back to git.** The tag `vX.Y.Z` is
   created *before* the binaries exist, so the immutable tag can never carry the
   checksum file — **`{:rover, github: ..., tag: "vX.Y.Z"}` installs therefore
   build from source** (`ROVER_BUILD=1`), they do *not* auto-download. Hex installs
   (`{:rover, "~> 0.1"}`) are the zero-build path. If you want *branch* git installs
   to download too, commit the checksums to the branch after the release:
   ```bash
   mix rover.runtime.download --all   # writes checksum-rover_runtime.exs
   git add checksum-rover_runtime.exs && git commit -m "Checksums for vX.Y.Z" && git push
   ```

> **`mix hex.build`/`hex.publish` require the checksum file.** It's listed in
> `mix.exs` `files:`, and Hex hard-errors on a missing listed file. The `publish`
> job generates it (step 3) before publishing; if you publish manually, run
> `mix rover.runtime.download --all` first.

### Verify the whole point afterwards
On a clean machine (or fresh `_build`/`deps`) with **no Rust toolchain and no Servo
checkout**:
```elixir
# mix.exs
{:rover, "~> 0.1"}
```
```bash
mix deps.get && mix compile     # the :rover_download compiler fetches the binary
```
If that drives a browser (`Rover.fetch("https://example.com")`), the release is good.

---

## Release ordering, at a glance

```
bump version + CHANGELOG  →  tag vX.Y.Z  →  release.yml builds 3 binaries
   →  GitHub release created (1 tarball + .sha256 per target)
   →  publish job (gated by `hex` env): generate checksum file → mix hex.publish
   →  verify clean install on a toolchain-free machine
```

The checksum file is **always** generated *after* the artifacts exist. Never
hand-edit it; never publish before it's regenerated.
