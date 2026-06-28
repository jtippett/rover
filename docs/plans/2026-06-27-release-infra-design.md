# Rover release / update / porting infra — design

_2026-06-27. Adopting ex_pdfium's release infra, adapted to Rover's architecture._

## Context & the architecture re-examination

Rover drives the **Servo** web engine from Elixir. Unlike ex_pdfium (a Rustler
**NIF** over a small C library, shipped via `rustler_precompiled`), Rover ships a
standalone **port binary** — `rover_runtime`, a Rust executable that embeds Servo
and speaks length-prefixed MessagePack over stdio. Elixir spawns one OS process
per browser.

Before porting infra we re-examined whether the port-binary model is still
justified (picking the project back up after a couple of months):

- **Multi-Servo-per-process is still impossible upstream.** Verified against
  `servo/servo@main` (vs. our pinned `678f9d7`): `OPTIONS.set(opts).expect("Already
  initialized")` (opts.rs:279), `Servo::new` calls `initialize_options`
  unconditionally (servo.rs:881), `script::init()` re-registers global SpiderMonkey
  vtables/statics with no re-entry guard (init.rs:182), and `static PREFERENCES:
  RwLock<Preferences>` remains process-global (prefs.rs:16). A second `Servo::new()`
  in one address space panics. Unchanged since April 2026.
- **The heavy build cost is Servo, not the process model.** Servo has no prebuilt
  embeddable `libservo` (unlike bblanchon's prebuilt `libpdfium`). Any embedding
  library must compile Servo from source. Switching to a NIF would *not* lighten
  the release; it would only cost crash isolation and the multi-browser / per-proxy
  capability that is Rover's reason to exist.

**Decision:** keep process-per-browser. It dominates a singleton NIF on isolation
and capability, and preserves optionality while the target workload is still open.
API altitude (automation verbs vs. thin Servo map) is cheap/reversible and deferred.

## What we're building

Parity with ex_pdfium's release ergonomics, adapted to a port binary:

1. **Zero-build install (the headline).** A custom Mix compiler `:rover_download`
   downloads the prebuilt `rover_runtime` from the GitHub release at `mix compile`
   and lands it in `priv/native/` (where `Rover.Runtime` already looks).
2. **Checksum verification.** A committed `checksum-rover_runtime.exs` maps each
   per-target tarball to its sha256; the compiler verifies before extracting.
3. **Interactive release** — `scripts/release.exs` + `just release`: bump `@version`,
   roll the CHANGELOG `[Unreleased]` section, commit, tag, push.
4. **Hex-gated CI publish** — a `publish` job in `release.yml`, gated by the `hex`
   GitHub environment (required-reviewer approval), regenerates checksums from the
   released artifacts and runs `mix hex.publish`.
5. **Docs** — `CHANGELOG.md` (`[Unreleased]` convention), `UPDATE_PROCEDURE.md`
   (release ordering + bumping the pinned Servo rev and the runtime binary),
   `PORTING.md` (the reusable playbook methodology).

## Auto-download mechanism

`Mix.Tasks.Compile.RoverDownload` (a `Mix.Task.Compiler`), added to `compilers:` in
`mix.exs`. On `mix compile`:

```
if priv/native/rover_runtime exists            -> :noop
elsif ROVER_BUILD=1                            -> :noop  (use local cargo build)
elsif target unsupported                       -> :noop  (fall back to local build)
elsif checksum file absent / target not in it  -> :noop  (unreleased dev version)
else -> download rover_runtime-v{version}-{target}.tar.gz from the
        GitHub release v{version}, verify sha256, extract rover_runtime
        into priv/native/, chmod +x
```

No NIF ABI version in the filename (it's an executable). `Rover.Runtime`'s existing
resolution order (`ROVER_RUNTIME_BIN` → `priv/native` → local target dirs) is
unchanged; the library's own dev/CI sets `ROVER_BUILD=1` to skip download and test
local code (mirrors ex_pdfium's `EXPDFIUM_BUILD=1`).

**Supported targets:** `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu`,
`aarch64-apple-darwin` (matches `release.yml`). GitHub repo: `jtippett/rover`.

### Testable (pure) seams — TDD these
- `target(os_type, arch_string)` → triple | `:unsupported`
- `archive_name(version, target)` → `"rover_runtime-v0.1.0-<target>.tar.gz"`
- `decision(binary_exists?, build_env?, target, checksums)` → `:download | :skip`
- `verify(bytes, "sha256:...")` → `:ok | {:error, ...}`

Network fetch + tar extraction stay thin wrappers around the pure core.

## Checksum generation

`mix rover.runtime.download --all --print` (mirrors `rustler_precompiled.download`):
downloads all per-target tarballs for the current `@version` from the GitHub release,
computes sha256, writes/prints `checksum-rover_runtime.exs`. Run in the `publish`
job before `mix hex.publish` so the Hex tarball carries verified checksums.

## Files

- `lib/mix/tasks/compile.rover_download.ex` — the compiler
- `lib/mix/tasks/rover.runtime.download.ex` — checksum generator
- `checksum-rover_runtime.exs` — generated, committed at release time
- `scripts/release.exs`, `justfile`, `CHANGELOG.md`
- `UPDATE_PROCEDURE.md`, `PORTING.md`
- `mix.exs` — `compilers:`, `package` `files:`, fix `@source_url`
- `.gitignore` — ignore `/priv/native/`
- `.github/workflows/release.yml` — add hex-gated `publish` job
