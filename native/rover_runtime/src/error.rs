//! Typed errors that cross the wire.
//!
//! Each variant maps to a `Rover.Error` reason atom on the Elixir side via the
//! tag string on `RoverError::tag()`. Keep the tags stable — they are part of
//! the public API.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, thiserror::Error)]
#[serde(tag = "kind", content = "message", rename_all = "snake_case")]
pub enum RoverError {
    #[error("timeout: {0}")]
    Timeout(String),

    #[error("navigation failed: {0}")]
    Navigation(String),

    #[error("selector not found: {0}")]
    SelectorNotFound(String),

    #[error("selector timeout: {0}")]
    SelectorTimeout(String),

    #[error("evaluation failed: {0}")]
    Evaluation(String),

    #[error("proxy error: {0}")]
    Proxy(String),

    #[error("invalid argument: {0}")]
    InvalidArgument(String),

    #[error("runtime error: {0}")]
    Runtime(String),

    #[error("shutting down")]
    Shutdown,
}

impl RoverError {
    /// Stable tag used by the Elixir side to dispatch on reason.
    #[allow(dead_code)]
    pub fn tag(&self) -> &'static str {
        match self {
            Self::Timeout(_) => "timeout",
            Self::Navigation(_) => "navigation",
            Self::SelectorNotFound(_) => "selector_not_found",
            Self::SelectorTimeout(_) => "selector_timeout",
            Self::Evaluation(_) => "evaluation",
            Self::Proxy(_) => "proxy",
            Self::InvalidArgument(_) => "invalid_argument",
            Self::Runtime(_) => "runtime",
            Self::Shutdown => "shutdown",
        }
    }
}

pub type Result<T> = std::result::Result<T, RoverError>;
