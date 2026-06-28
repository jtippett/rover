# Changelog

All notable changes to Rover are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) against
Rover's own Elixir API (not Servo's).

The `## [Unreleased]` section is rolled into a dated, versioned heading by
`scripts/release.exs` (`just release`) when a release is cut.

## [Unreleased]

### Added
- Precompiled `rover_runtime` binaries: a `:rover_download` Mix compiler fetches
  the prebuilt binary for the host target from the GitHub release at `mix compile`
  and verifies it against `checksum-rover_runtime.exs`, so consumers install
  without a Rust toolchain or a Servo build. Set `ROVER_BUILD=1` to skip the
  download and use a local `cargo` build instead.

## 0.1.0

Initial release. Drive the Servo web engine from Elixir — one OS process per
browser, with per-instance proxy config, cookies, JS evaluation, and input
automation.

### Added
- `Rover.fetch/2` (one-shot) and `Rover.start_link/1` (long-lived, supervisable)
  browser instances, each backed by a dedicated `rover_runtime` OS subprocess
  spoken to over length-prefixed MessagePack (`Port`, `packet: 4`).
- Navigation, rendered content, title; `wait_for/3` polling for JS-rendered nodes.
- JavaScript evaluation (`evaluate/2`) round-tripping strings, numbers, arrays,
  and maps.
- Text/attribute extraction (`get_text`, `get_texts`, `get_attribute`).
- Real input automation: `click`, `fill`, `hover`, `select_option` dispatching
  genuine DOM events.
- PNG/JPEG screenshots (`screenshot/2`).
- Cookie management via Servo's `SiteDataManager` (`get_cookies`, `set_cookie`,
  `clear_*`).
- Per-instance proxy routing — the point of Rover.
