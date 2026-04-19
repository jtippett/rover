//! Servo embedding — the actual browser.
//!
//! The `Engine` owns a single `Servo` instance and a single `WebView`. It is
//! built once from an `Init` request, then serves a synchronous
//! request/response loop until the runtime exits.
//!
//! Everything Servo-facing stays on the main thread: Servo contains `!Send`
//! and `!Sync` types and must be driven from one thread.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use dpi::PhysicalSize;
use image::{
    ColorType, ImageEncoder, RgbaImage, codecs::jpeg::JpegEncoder, codecs::png::PngEncoder,
};
use log::info;
use servo::{
    DevicePoint, EventLoopWaker, InputEvent, JSValue, LoadStatus, MouseButton, MouseButtonAction,
    MouseButtonEvent, MouseMoveEvent, Preferences, RenderingContext, Servo, ServoBuilder,
    SoftwareRenderingContext, WebView, WebViewBuilder, WebViewDelegate, WebViewPoint,
};
use url::Url;

use crate::error::{Result, RoverError};
use crate::protocol::{CookieInfo, ImageFormat, JsonValue, PageInfo, Request, Response, Viewport};

const SPIN_SLEEP: Duration = Duration::from_millis(1);
const WAIT_POLL_INTERVAL: Duration = Duration::from_millis(25);
const INPUT_SETTLE: Duration = Duration::from_millis(50);

// ── Engine ──────────────────────────────────────────────────────────────────

pub struct Engine {
    servo: Servo,
    webview: WebView,
    _rendering_context: Rc<SoftwareRenderingContext>,
    _waker: Arc<AtomicBool>,
    _delegate: Rc<NullDelegate>,
}

impl Engine {
    pub fn new(
        proxy: String,
        _user_agent: Option<String>,
        viewport: Option<Viewport>,
    ) -> Result<Self> {
        let Viewport { width, height } = viewport.unwrap_or_default();

        info!(
            "initializing engine (proxy={}, viewport={width}x{height})",
            if proxy.is_empty() { "<direct>" } else { &proxy }
        );

        let rendering_context = Rc::new(
            SoftwareRenderingContext::new(PhysicalSize { width, height })
                .map_err(|e| RoverError::Runtime(format!("rendering context: {e:?}")))?,
        );

        rendering_context
            .make_current()
            .map_err(|e| RoverError::Runtime(format!("make_current: {e:?}")))?;

        let waker = Arc::new(AtomicBool::new(false));
        let mut preferences = Preferences::default();
        preferences.network_http_proxy_uri = proxy.clone();
        preferences.network_https_proxy_uri = proxy;

        let servo = ServoBuilder::default()
            .preferences(preferences)
            .event_loop_waker(Box::new(Waker(waker.clone())))
            .build();

        let delegate = Rc::new(NullDelegate);

        // Build the single WebView pointed at about:blank. Subsequent navigate
        // requests reuse this WebView via webview.load(url).
        let blank = Url::parse("about:blank").expect("about:blank parses");
        let webview = WebViewBuilder::new(&servo, rendering_context.clone())
            .delegate(delegate.clone())
            .url(blank)
            .build();

        let mut engine = Self {
            servo,
            webview,
            _rendering_context: rendering_context,
            _waker: waker,
            _delegate: delegate,
        };

        engine.wait_for_load(30_000)?;

        Ok(engine)
    }

    pub fn handle(&mut self, request: Request) -> Response {
        match request {
            Request::Init { .. } | Request::Shutdown => {
                // Dispatched in wire.rs before reaching the engine.
                Response::Error {
                    error: RoverError::Runtime(
                        "Init/Shutdown must be handled by dispatcher".into(),
                    ),
                }
            }

            Request::Navigate { url, timeout_ms } => to_page_info(self.navigate(&url, timeout_ms)),
            Request::CurrentUrl => to_text(self.current_url()),
            Request::Content => to_text(self.content()),
            Request::Title => to_text(self.title()),

            Request::Evaluate { expression } => to_value(self.evaluate(&expression)),

            Request::WaitFor {
                selector,
                timeout_ms,
            } => to_ack(self.wait_for_selector(&selector, timeout_ms)),

            Request::GetText { selector } => to_text(self.get_text(&selector)),
            Request::GetTexts { selector } => to_texts(self.get_texts(&selector)),
            Request::GetAttribute { selector, name } => {
                to_value(self.get_attribute(&selector, &name))
            }

            Request::Click { selector } => to_ack(self.click(&selector)),
            Request::Fill { selector, value } => to_ack(self.fill(&selector, &value)),
            Request::Hover { selector } => to_ack(self.hover(&selector)),
            Request::SelectOption { selector, value } => {
                to_ack(self.select_option(&selector, &value))
            }

            Request::Screenshot { format, quality } => to_image(self.screenshot(format, quality)),

            Request::GetCookies => to_cookies(self.get_cookies()),
            Request::SetCookie { cookie } => to_ack(self.set_cookie(&cookie)),
            Request::ClearCookies => to_ack(self.clear_cookies()),
        }
    }

    // ── navigation ─────────────────────────────────────────────────────────

    fn navigate(&mut self, url: &str, timeout_ms: u64) -> Result<PageInfo> {
        let parsed =
            Url::parse(url).map_err(|e| RoverError::Navigation(format!("bad URL: {e}")))?;
        self.webview.load(parsed.clone());

        // `load_status` may already be `Complete` from the previous page —
        // waiting on it immediately would short-circuit. Instead, wait for
        // the WebView's URL to reflect our target (meaning Servo has started
        // processing the navigation), *then* wait for completion.
        let webview = self.webview.clone();
        let target = parsed;

        self.spin_until(timeout_ms, || {
            webview.url().map(|u| u != target).unwrap_or(true)
        })?;

        let webview = self.webview.clone();
        self.spin_until(timeout_ms, || webview.load_status() != LoadStatus::Complete)?;

        Ok(self.page_info())
    }

    fn current_url(&mut self) -> Result<String> {
        Ok(self
            .webview
            .url()
            .map(|u| u.to_string())
            .unwrap_or_else(|| "about:blank".into()))
    }

    fn page_info(&self) -> PageInfo {
        PageInfo {
            url: self
                .webview
                .url()
                .map(|u| u.to_string())
                .unwrap_or_else(|| "about:blank".into()),
            title: self.webview.page_title().unwrap_or_default(),
        }
    }

    // ── content ────────────────────────────────────────────────────────────

    fn content(&mut self) -> Result<String> {
        let value = self.evaluate_raw("document.documentElement.outerHTML")?;
        string_of(value).ok_or_else(|| RoverError::Evaluation("content returned non-string".into()))
    }

    fn title(&mut self) -> Result<String> {
        if let Some(title) = self.webview.page_title() {
            return Ok(title);
        }
        let value = self.evaluate_raw("document.title")?;
        Ok(string_of(value).unwrap_or_default())
    }

    // ── evaluation ─────────────────────────────────────────────────────────

    fn evaluate(&mut self, expression: &str) -> Result<JsonValue> {
        let value = self.evaluate_raw(expression)?;
        Ok(json_of(value))
    }

    fn evaluate_raw(&mut self, expression: &str) -> Result<JSValue> {
        self.wait_for_load(30_000)?;

        let stored: Rc<RefCell<Option<std::result::Result<JSValue, String>>>> =
            Rc::new(RefCell::new(None));
        let stored_cb = stored.clone();

        self.webview
            .evaluate_javascript(expression.to_string(), move |result| {
                *stored_cb.borrow_mut() = Some(match result {
                    Ok(value) => Ok(value),
                    Err(err) => Err(format!("{err:?}")),
                });
            });

        self.spin_until(30_000, || stored.borrow().is_none())?;

        match stored.borrow_mut().take() {
            Some(Ok(value)) => Ok(value),
            Some(Err(message)) => Err(RoverError::Evaluation(message)),
            None => Err(RoverError::Evaluation(
                "evaluator returned no result".into(),
            )),
        }
    }

    // ── waiting ────────────────────────────────────────────────────────────

    fn wait_for_selector(&mut self, selector: &str, timeout_ms: u64) -> Result<()> {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);

        loop {
            if self.selector_exists(selector)? {
                return Ok(());
            }

            if Instant::now() >= deadline {
                return Err(RoverError::SelectorTimeout(selector.to_string()));
            }

            self.spin_for(WAIT_POLL_INTERVAL);
        }
    }

    fn selector_exists(&mut self, selector: &str) -> Result<bool> {
        let script = format!(
            "(() => document.querySelector({}) !== null)()",
            quote_js(selector)
        );
        match self.evaluate_raw(&script)? {
            JSValue::Boolean(b) => Ok(b),
            other => Err(RoverError::Evaluation(format!(
                "selector_exists expected bool, got {other:?}"
            ))),
        }
    }

    // ── extraction ─────────────────────────────────────────────────────────

    fn get_text(&mut self, selector: &str) -> Result<String> {
        let script = format!(
            "(() => {{ const el = document.querySelector({s}); \
               if (!el) return null; \
               return (el.innerText ?? el.textContent ?? '').trim(); }})()",
            s = quote_js(selector)
        );

        match self.evaluate_raw(&script)? {
            JSValue::String(s) => Ok(s),
            JSValue::Null | JSValue::Undefined => {
                Err(RoverError::SelectorNotFound(selector.to_string()))
            }
            other => Err(RoverError::Evaluation(format!(
                "get_text expected string, got {other:?}"
            ))),
        }
    }

    fn get_texts(&mut self, selector: &str) -> Result<Vec<String>> {
        let script = format!(
            "Array.from(document.querySelectorAll({s})) \
               .map(el => (el.innerText ?? el.textContent ?? '').trim())",
            s = quote_js(selector)
        );

        match self.evaluate_raw(&script)? {
            JSValue::Array(items) => Ok(items
                .into_iter()
                .map(|v| string_of(v).unwrap_or_default())
                .collect()),
            other => Err(RoverError::Evaluation(format!(
                "get_texts expected array, got {other:?}"
            ))),
        }
    }

    fn get_attribute(&mut self, selector: &str, name: &str) -> Result<JsonValue> {
        let script = format!(
            "(() => {{ const el = document.querySelector({s}); \
               if (!el) return null; \
               return el.getAttribute({n}); }})()",
            s = quote_js(selector),
            n = quote_js(name)
        );

        match self.evaluate_raw(&script)? {
            JSValue::Null => Err(RoverError::SelectorNotFound(selector.to_string())),
            other => Ok(json_of(other)),
        }
    }

    // ── interaction ────────────────────────────────────────────────────────

    fn click(&mut self, selector: &str) -> Result<()> {
        self.wait_for_load(30_000)?;
        self.wait_for_selector(selector, 30_000)?;
        let point = self.selector_center(selector)?;
        let wv_point = WebViewPoint::Device(point);

        self.webview
            .notify_input_event(InputEvent::MouseMove(MouseMoveEvent::new(wv_point)));
        self.webview
            .notify_input_event(InputEvent::MouseButton(MouseButtonEvent::new(
                MouseButtonAction::Down,
                MouseButton::Left,
                wv_point,
            )));
        self.webview
            .notify_input_event(InputEvent::MouseButton(MouseButtonEvent::new(
                MouseButtonAction::Up,
                MouseButton::Left,
                wv_point,
            )));

        self.spin_for(INPUT_SETTLE);
        Ok(())
    }

    fn fill(&mut self, selector: &str, value: &str) -> Result<()> {
        self.wait_for_load(30_000)?;
        self.wait_for_selector(selector, 30_000)?;

        // One-shot script that focuses the element, writes the value, and fires
        // input + change events so frameworks (React, Vue, etc.) pick up the
        // change. Returns true iff the post-write value matches `value`.
        let script = format!(
            "(() => {{ \
               const el = document.querySelector({s}); \
               if (!el) return false; \
               if (typeof el.focus === 'function') el.focus(); \
               if ('value' in el) {{ el.value = {v}; }} \
               else {{ el.textContent = {v}; el.setAttribute('value', {v}); }} \
               try {{ el.dispatchEvent(new Event('input', {{ bubbles: true }})); }} catch (_) {{}} \
               try {{ el.dispatchEvent(new Event('change', {{ bubbles: true }})); }} catch (_) {{}} \
               return ('value' in el ? el.value : el.textContent) === {v}; \
             }})()",
            s = quote_js(selector),
            v = quote_js(value)
        );

        match self.evaluate_raw(&script)? {
            JSValue::Boolean(true) => Ok(()),
            JSValue::Boolean(false) => Err(RoverError::SelectorNotFound(selector.to_string())),
            other => Err(RoverError::Evaluation(format!(
                "fill expected bool, got {other:?}"
            ))),
        }
    }

    fn hover(&mut self, selector: &str) -> Result<()> {
        self.wait_for_load(30_000)?;
        self.wait_for_selector(selector, 30_000)?;
        let point = self.selector_center(selector)?;
        let wv_point = WebViewPoint::Device(point);

        self.webview
            .notify_input_event(InputEvent::MouseMove(MouseMoveEvent::new(wv_point)));

        self.spin_for(INPUT_SETTLE);
        Ok(())
    }

    fn select_option(&mut self, selector: &str, value: &str) -> Result<()> {
        self.wait_for_load(30_000)?;
        self.wait_for_selector(selector, 30_000)?;

        let script = format!(
            "(() => {{ \
               const el = document.querySelector({s}); \
               if (!el) return 'not_found'; \
               if (!(el instanceof HTMLSelectElement)) return 'not_select'; \
               const opt = Array.from(el.options).find(o => o.value === {v}); \
               if (!opt) return 'option_not_found'; \
               el.value = {v}; \
               try {{ el.dispatchEvent(new Event('input', {{ bubbles: true }})); }} catch (_) {{}} \
               try {{ el.dispatchEvent(new Event('change', {{ bubbles: true }})); }} catch (_) {{}} \
               return 'ok'; \
             }})()",
            s = quote_js(selector),
            v = quote_js(value)
        );

        match self.evaluate_raw(&script)? {
            JSValue::String(s) if s == "ok" => Ok(()),
            JSValue::String(s) if s == "not_found" => {
                Err(RoverError::SelectorNotFound(selector.to_string()))
            }
            JSValue::String(s) if s == "not_select" => Err(RoverError::InvalidArgument(
                "selector did not match a <select>".into(),
            )),
            JSValue::String(s) if s == "option_not_found" => Err(RoverError::InvalidArgument(
                format!("<option value=\"{value}\"> not present"),
            )),
            other => Err(RoverError::Evaluation(format!(
                "select_option expected string, got {other:?}"
            ))),
        }
    }

    fn selector_center(&mut self, selector: &str) -> Result<DevicePoint> {
        let script = format!(
            "(() => {{ const el = document.querySelector({s}); \
               if (!el) return null; \
               const r = el.getBoundingClientRect(); \
               return [r.left + r.width / 2, r.top + r.height / 2]; }})()",
            s = quote_js(selector)
        );

        match self.evaluate_raw(&script)? {
            JSValue::Array(values) if values.len() == 2 => {
                let x = number_of(&values[0])
                    .ok_or_else(|| RoverError::Evaluation("bounding x not a number".into()))?;
                let y = number_of(&values[1])
                    .ok_or_else(|| RoverError::Evaluation("bounding y not a number".into()))?;
                Ok(DevicePoint::new(x as f32, y as f32))
            }
            JSValue::Null => Err(RoverError::SelectorNotFound(selector.to_string())),
            other => Err(RoverError::Evaluation(format!(
                "unexpected selector_center result: {other:?}"
            ))),
        }
    }

    // ── capture ────────────────────────────────────────────────────────────

    fn screenshot(&mut self, format: ImageFormat, quality: u8) -> Result<Vec<u8>> {
        self.wait_for_load(30_000)?;

        let stored: Rc<RefCell<Option<std::result::Result<RgbaImage, String>>>> =
            Rc::new(RefCell::new(None));
        let stored_cb = stored.clone();

        self.webview.take_screenshot(None, move |result| {
            *stored_cb.borrow_mut() = Some(match result {
                Ok(image) => Ok(image),
                Err(e) => Err(format!("{e:?}")),
            });
        });

        self.spin_until(30_000, || stored.borrow().is_none())?;

        let image = match stored.borrow_mut().take() {
            Some(Ok(image)) => image,
            Some(Err(e)) => return Err(RoverError::Runtime(format!("screenshot: {e}"))),
            None => return Err(RoverError::Runtime("screenshot: no result".into())),
        };

        encode_image(&image, format, quality)
    }

    // ── cookies ────────────────────────────────────────────────────────────

    fn get_cookies(&mut self) -> Result<Vec<CookieInfo>> {
        let Some(url) = self.webview.url() else {
            return Ok(vec![]);
        };

        let cookies = self
            .servo
            .site_data_manager()
            .cookies_for_url(url, servo::CookieSource::HTTP);

        Ok(cookies.into_iter().map(cookie_to_wire).collect())
    }

    fn set_cookie(&mut self, cookie_string: &str) -> Result<()> {
        let url = self
            .webview
            .url()
            .ok_or_else(|| RoverError::Runtime("cannot set cookie without current URL".into()))?;

        let parsed = cookie::Cookie::parse(cookie_string.to_string())
            .map_err(|e| RoverError::InvalidArgument(format!("bad cookie: {e}")))?;

        self.servo
            .site_data_manager()
            .set_cookie_for_url(url, parsed);
        Ok(())
    }

    fn clear_cookies(&mut self) -> Result<()> {
        self.servo.site_data_manager().clear_cookies();
        Ok(())
    }

    // ── pump ───────────────────────────────────────────────────────────────

    fn wait_for_load(&mut self, timeout_ms: u64) -> Result<()> {
        let webview = self.webview.clone();
        self.spin_until(timeout_ms, || webview.load_status() != LoadStatus::Complete)
    }

    fn spin_until(&mut self, timeout_ms: u64, pending: impl Fn() -> bool) -> Result<()> {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);

        while pending() {
            self.servo.spin_event_loop();
            if Instant::now() >= deadline {
                return Err(RoverError::Timeout(format!("exceeded {timeout_ms}ms")));
            }
            thread::sleep(SPIN_SLEEP);
        }

        Ok(())
    }

    fn spin_for(&mut self, duration: Duration) {
        let deadline = Instant::now() + duration;
        while Instant::now() < deadline {
            self.servo.spin_event_loop();
            thread::sleep(SPIN_SLEEP);
        }
    }
}

// ── response helpers ─────────────────────────────────────────────────────────

fn to_page_info(result: Result<PageInfo>) -> Response {
    match result {
        Ok(info) => Response::PageInfo {
            url: info.url,
            title: info.title,
        },
        Err(error) => Response::Error { error },
    }
}

fn to_ack(result: Result<()>) -> Response {
    match result {
        Ok(()) => Response::Ack,
        Err(error) => Response::Error { error },
    }
}

fn to_text(result: Result<String>) -> Response {
    match result {
        Ok(string) => Response::Text { string },
        Err(error) => Response::Error { error },
    }
}

fn to_texts(result: Result<Vec<String>>) -> Response {
    match result {
        Ok(strings) => Response::Texts { strings },
        Err(error) => Response::Error { error },
    }
}

fn to_value(result: Result<JsonValue>) -> Response {
    match result {
        Ok(value) => Response::Value { value },
        Err(error) => Response::Error { error },
    }
}

fn to_image(result: Result<Vec<u8>>) -> Response {
    match result {
        Ok(bytes) => Response::Image { bytes },
        Err(error) => Response::Error { error },
    }
}

fn to_cookies(result: Result<Vec<CookieInfo>>) -> Response {
    match result {
        Ok(cookies) => Response::Cookies { cookies },
        Err(error) => Response::Error { error },
    }
}

// ── JS value conversion ─────────────────────────────────────────────────────

fn json_of(value: JSValue) -> JsonValue {
    match value {
        JSValue::Undefined | JSValue::Null => JsonValue::Null,
        JSValue::Boolean(b) => JsonValue::Bool(b),
        JSValue::Number(n) => number_to_json(n),
        JSValue::String(s) => JsonValue::String(s),
        JSValue::Element(s) | JSValue::ShadowRoot(s) | JSValue::Frame(s) | JSValue::Window(s) => {
            JsonValue::String(s)
        }
        JSValue::Array(items) => JsonValue::Array(items.into_iter().map(json_of).collect()),
        JSValue::Object(map) => {
            JsonValue::Object(map.into_iter().map(|(k, v)| (k, json_of(v))).collect())
        }
    }
}

fn number_to_json(n: f64) -> JsonValue {
    if n.is_finite() && n.fract() == 0.0 && n >= i64::MIN as f64 && n <= i64::MAX as f64 {
        JsonValue::Int(n as i64)
    } else {
        JsonValue::Float(n)
    }
}

fn string_of(value: JSValue) -> Option<String> {
    match value {
        JSValue::String(s) => Some(s),
        _ => None,
    }
}

fn number_of(value: &JSValue) -> Option<f64> {
    match value {
        JSValue::Number(n) => Some(*n),
        _ => None,
    }
}

// ── JS escaping ──────────────────────────────────────────────────────────────

fn quote_js(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\0' => out.push_str("\\0"),
            c if (c as u32) < 0x20 => {
                use std::fmt::Write;
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// ── image encoding ───────────────────────────────────────────────────────────

fn encode_image(image: &RgbaImage, format: ImageFormat, quality: u8) -> Result<Vec<u8>> {
    let (w, h) = image.dimensions();
    let mut buf = Vec::new();

    match format {
        ImageFormat::Png => {
            PngEncoder::new(&mut buf)
                .write_image(image.as_raw(), w, h, ColorType::Rgba8.into())
                .map_err(|e| RoverError::Runtime(format!("png encode: {e}")))?;
        }
        ImageFormat::Jpeg => {
            let quality = quality.clamp(1, 100);
            JpegEncoder::new_with_quality(&mut buf, quality)
                .encode(image.as_raw(), w, h, ColorType::Rgba8.into())
                .map_err(|e| RoverError::Runtime(format!("jpeg encode: {e}")))?;
        }
    }

    Ok(buf)
}

// ── cookie conversion ────────────────────────────────────────────────────────

fn cookie_to_wire(c: cookie::Cookie<'static>) -> CookieInfo {
    CookieInfo {
        name: c.name().to_string(),
        value: c.value().to_string(),
        domain: c.domain().unwrap_or_default().to_string(),
        path: c.path().unwrap_or("/").to_string(),
        secure: c.secure().unwrap_or(false),
        http_only: c.http_only().unwrap_or(false),
        expires: c.expires().and_then(|e| match e {
            cookie::Expiration::DateTime(dt) => Some(dt.unix_timestamp()),
            cookie::Expiration::Session => None,
        }),
    }
}

// ── Servo plumbing ──────────────────────────────────────────────────────────

#[derive(Clone)]
struct Waker(Arc<AtomicBool>);

impl EventLoopWaker for Waker {
    fn clone_box(&self) -> Box<dyn EventLoopWaker> {
        Box::new(self.clone())
    }

    fn wake(&self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

#[derive(Default)]
struct NullDelegate;

impl WebViewDelegate for NullDelegate {
    fn notify_new_frame_ready(&self, webview: WebView) {
        webview.paint();
    }
}
