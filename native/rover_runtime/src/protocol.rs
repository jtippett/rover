//! Wire protocol — every frame type that travels between Elixir and the runtime.
//!
//! The Elixir side has a mirrored set of structs/tags in `Rover.Protocol`.
//! When adding a variant: add it here, add the Elixir mirror, bump the
//! protocol version. Never renumber or repurpose existing variants.

use serde::{Deserialize, Serialize};
use serde_bytes::ByteBuf;

use crate::error::RoverError;

/// Protocol version announced by the runtime in its `Hello` notification.
/// Bump when adding or changing variants in an incompatible way.
pub const PROTOCOL_VERSION: u32 = 1;

/// Everything the Elixir side can send.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// Initialize the browser. Must be the first request. Sets proxy/user_agent
    /// and builds the WebView. `proxy` is an empty string for no proxy.
    Init {
        proxy: String,
        user_agent: Option<String>,
        viewport: Option<Viewport>,
    },

    /// Navigate to a URL; blocks until the page reports `LoadStatus::Complete`
    /// or `timeout_ms` elapses.
    Navigate { url: String, timeout_ms: u64 },

    /// Document URL after redirects.
    CurrentUrl,

    /// `document.documentElement.outerHTML`.
    Content,

    /// `document.title` (falls back to JS eval).
    Title,

    /// Evaluate a JavaScript expression and return the result.
    Evaluate { expression: String },

    /// Block until a CSS selector matches at least one element, or `timeout_ms`.
    WaitFor { selector: String, timeout_ms: u64 },

    /// `querySelector(s).innerText`.
    GetText { selector: String },

    /// `querySelectorAll(s)` → `innerText` per match.
    GetTexts { selector: String },

    /// `querySelector(s).getAttribute(name)`.
    GetAttribute { selector: String, name: String },

    /// Click the element (center of its bounding box).
    Click { selector: String },

    /// Set the value of an input/textarea and dispatch input + change events.
    Fill { selector: String, value: String },

    /// Mouse-move over the element's center.
    Hover { selector: String },

    /// Set the value of a `<select>` by option value.
    SelectOption { selector: String, value: String },

    /// Take a screenshot. `format` is `"png"` or `"jpeg"`; `quality` applies to
    /// JPEG only (1..=100, ignored for PNG).
    Screenshot { format: ImageFormat, quality: u8 },

    /// Cookies visible to the current document URL.
    GetCookies,

    /// Parse and install a cookie for the current document URL.
    SetCookie { cookie: String },

    /// Clear the cookie jar.
    ClearCookies,

    /// Graceful shutdown. Runtime replies with `Ack` then exits.
    Shutdown,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImageFormat {
    Png,
    Jpeg,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Viewport {
    pub width: u32,
    pub height: u32,
}

impl Default for Viewport {
    fn default() -> Self {
        Self {
            width: 1280,
            height: 720,
        }
    }
}

/// Everything the runtime can send in reply to a `Request`.
///
/// Each variant serializes as `{"kind": "<name>", <fields...>}` — struct-shape
/// on purpose so field names appear directly in the map, matching the Elixir
/// side's pattern matches.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Response {
    Ack,
    PageInfo {
        url: String,
        title: String,
    },
    Text {
        string: String,
    },
    Texts {
        strings: Vec<String>,
    },
    Value {
        value: JsonValue,
    },
    Image {
        #[serde(with = "serde_bytes")]
        bytes: Vec<u8>,
    },
    Cookies {
        cookies: Vec<CookieInfo>,
    },
    Error {
        error: RoverError,
    },
}

/// Basic page metadata returned by `Navigate` / `CurrentUrl` / `Title`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageInfo {
    pub url: String,
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CookieInfo {
    pub name: String,
    pub value: String,
    pub domain: String,
    pub path: String,
    pub secure: bool,
    pub http_only: bool,
    /// Seconds since unix epoch, or None for session cookies.
    pub expires: Option<i64>,
}

/// A generic JS value. Mirrors `Jason.decode/1`-style shapes on the Elixir side.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum JsonValue {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    Array(Vec<JsonValue>),
    Object(std::collections::BTreeMap<String, JsonValue>),
    Binary(ByteBuf),
}

/// Out-of-band messages from runtime to Elixir — not tied to a request id.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Notification {
    /// Sent once, right after startup. Announces protocol version + runtime version.
    Hello {
        protocol_version: u32,
        runtime_version: String,
    },

    /// Informational log line surfaced from the runtime. Elixir side usually
    /// forwards to Logger.
    Log { level: LogLevel, message: String },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

/// Top-level inbound envelope: `{id, request}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Envelope<T> {
    pub id: u64,
    #[serde(flatten)]
    pub payload: T,
}
