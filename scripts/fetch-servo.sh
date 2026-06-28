#!/usr/bin/env bash
# Clone the Servo source into ./servo_rust at the pinned revision, for local
# dev/test. rover_runtime depends on Servo as a *path* dep
# (native/rover_runtime/Cargo.toml → ../../servo_rust/components/servo), so the
# tree must exist before `cargo build`.
#
#   scripts/fetch-servo.sh [<rev>]
#
# Keep the default rev in sync with native/rover_runtime/Cargo.toml and the
# `ref:` in .github/workflows/release.yml (see UPDATE_PROCEDURE.md).
set -euo pipefail

# Pinned Servo revision. Update this, Cargo.toml, and release.yml together.
REV="${1:-678f9d7a47778d2a02ca5e1d2ee4b3cd2b3c2bc8}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/servo_rust"

if [ -d "$DEST/.git" ]; then
  echo "servo_rust already present — fetching $REV ..."
  git -C "$DEST" fetch --filter=blob:none origin "$REV" || git -C "$DEST" fetch origin
  git -C "$DEST" checkout --quiet "$REV"
else
  echo "Cloning Servo (blobless partial clone — full history, blobs on demand) ..."
  # --filter=blob:none keeps the clone small while still letting us check out
  # an arbitrary historical rev (a shallow clone could miss it).
  git clone --filter=blob:none --no-checkout https://github.com/servo/servo "$DEST"
  git -C "$DEST" checkout --quiet "$REV"
fi

echo "Servo checked out at $REV -> $DEST"
echo "Now: cd native/rover_runtime && cargo build   (or: mix rover.build)"
