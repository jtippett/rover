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
use std::thread;
use std::time::Duration;

use log::{error, info, warn};

/// Exit when the parent (the BEAM's spawner) dies, no matter what the main
/// thread is doing. The wire loop's exit paths — Shutdown frame, stdin EOF,
/// stdout write failure — all require the main thread to be back in the read
/// loop; if Servo wedges mid-operation, none of them ever fire and the
/// process outlives the BEAM, spinning. Observed in the wild: orphaned
/// runtimes at ~150% CPU for days. `process::exit` on purpose — destructors
/// may be exactly what is wedged.
fn spawn_parent_watchdog() {
    let initial_parent = std::os::unix::process::parent_id();

    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(1));

            let parent = std::os::unix::process::parent_id();
            if parent == 1 || parent != initial_parent {
                warn!("parent process gone (ppid now {parent}); exiting");
                std::process::exit(0);
            }
        }
    });
}

fn main() -> ExitCode {
    env_logger::Builder::from_env(
        env_logger::Env::default()
            .default_filter_or("warn,rover_runtime=info,profile_traits::mem=error"),
    )
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

    spawn_parent_watchdog();

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
