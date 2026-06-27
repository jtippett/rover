# Project commands. Run `just --list` to see them all.

# Interactive release: pick patch/minor/major, roll the CHANGELOG, tag & push.
release:
    elixir scripts/release.exs

# Run the test suite against the locally-built runtime binary.
test:
    # ROVER_BUILD=1 forces the local build so the :rover_download compiler doesn't
    # fetch a released artifact over the code under test.
    ROVER_BUILD=1 mix test

# Format Elixir + Rust.
fmt:
    mix format
    # rustfmt directly (not `cargo fmt`) so it doesn't drag in Servo's dep graph.
    rustfmt --edition 2024 native/rover_runtime/src/*.rs

# Clone Servo into ./servo_rust at the pinned rev (needed before cargo build).
servo rev="678f9d7a47778d2a02ca5e1d2ee4b3cd2b3c2bc8":
    scripts/fetch-servo.sh {{rev}}

# Build the runtime binary (release). Requires servo_rust/ (run `just servo` first).
build:
    mix rover.build

# Regenerate checksum-rover_runtime.exs from a published release's artifacts.
checksums:
    # Run after the release.yml build matrix has attached the tarballs.
    mix rover.runtime.download --all --print
