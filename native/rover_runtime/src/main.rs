//! Rover runtime: per-browser Servo process, driven by Elixir over stdio.
//!
//! Wire format: length-prefixed (u32 big-endian) MessagePack frames.
//! Inbound: `Request`. Outbound: `Response` or `Notification`.
//!
//! Exits when stdin closes or when a `Shutdown` request is received.

#![forbid(unsafe_code)]

mod engine;
mod error;
mod protocol;
mod wire;

use std::io::{self, IsTerminal};
use std::process::ExitCode;

use log::{error, info};

fn main() -> ExitCode {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .target(env_logger::Target::Stderr)
        .init();

    if io::stdin().is_terminal() {
        eprintln!(
            "rover_runtime is a subprocess driven by the Rover Elixir library.\n\
             It is not meant to be run interactively. See https://hex.pm/packages/rover"
        );
        return ExitCode::from(2);
    }

    info!("rover_runtime v{} starting", env!("CARGO_PKG_VERSION"));

    match wire::run() {
        Ok(()) => {
            info!("rover_runtime shutting down cleanly");
            ExitCode::SUCCESS
        }
        Err(e) => {
            error!("rover_runtime terminated with error: {e}");
            ExitCode::FAILURE
        }
    }
}
