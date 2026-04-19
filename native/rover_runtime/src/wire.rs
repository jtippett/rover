//! Length-prefixed MessagePack framing over stdin/stdout.
//!
//! Every frame is a 4-byte big-endian length followed by that many bytes of
//! MessagePack payload. Elixir's `:packet => 4` port option speaks the same
//! framing natively, so the Elixir side never handles raw bytes.

use std::io::{self, BufReader, Read, Write};

use crate::engine::Engine;
use crate::error::RoverError;
use crate::protocol::{Envelope, Notification, Request, Response, PROTOCOL_VERSION};

const MAX_FRAME_LEN: u32 = 64 * 1024 * 1024; // 64 MiB; screenshots can be large

pub fn run() -> io::Result<()> {
    let mut stdin = BufReader::new(io::stdin().lock());
    let mut stdout = io::stdout().lock();

    write_notification(
        &mut stdout,
        &Notification::Hello {
            protocol_version: PROTOCOL_VERSION,
            runtime_version: env!("CARGO_PKG_VERSION").to_string(),
        },
    )?;

    let mut engine: Option<Engine> = None;

    loop {
        let frame = match read_frame(&mut stdin)? {
            Some(bytes) => bytes,
            None => return Ok(()),
        };

        let envelope: Envelope<Request> = match rmp_serde::from_slice(&frame) {
            Ok(e) => e,
            Err(e) => {
                log::error!("malformed request frame: {e}");
                continue;
            }
        };

        let id = envelope.id;
        let request = envelope.payload;
        let shutting_down = matches!(request, Request::Shutdown);

        let response = dispatch(&mut engine, request);
        write_response(&mut stdout, id, &response)?;

        if shutting_down {
            return Ok(());
        }
    }
}

fn dispatch(engine: &mut Option<Engine>, request: Request) -> Response {
    match request {
        Request::Init { proxy, user_agent, viewport } => match Engine::new(proxy, user_agent, viewport) {
            Ok(new_engine) => {
                *engine = Some(new_engine);
                Response::Ack
            }
            Err(e) => Response::Error { error: e },
        },
        Request::Shutdown => Response::Ack,
        other => match engine.as_mut() {
            Some(engine) => engine.handle(other),
            None => Response::Error {
                error: RoverError::Runtime(
                    "runtime not initialized (send Init first)".into(),
                ),
            },
        },
    }
}

fn read_frame(r: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match r.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }

    let len = u32::from_be_bytes(len_buf);
    if len > MAX_FRAME_LEN {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame {len} exceeds MAX_FRAME_LEN ({MAX_FRAME_LEN})"),
        ));
    }

    let mut buf = vec![0u8; len as usize];
    r.read_exact(&mut buf)?;
    Ok(Some(buf))
}

fn write_response(w: &mut impl Write, id: u64, response: &Response) -> io::Result<()> {
    // Outbound envelope: `{id, kind: "response", payload: ...}`.
    // The Elixir side uses `id == 0` to mean "out-of-band notification".
    let envelope = OutboundEnvelope { id, kind: "response", response: Some(response), notification: None };
    write_envelope(w, &envelope)
}

fn write_notification(w: &mut impl Write, notification: &Notification) -> io::Result<()> {
    let envelope = OutboundEnvelope {
        id: 0,
        kind: "notification",
        response: None,
        notification: Some(notification),
    };
    write_envelope(w, &envelope)
}

fn write_envelope<'a>(w: &mut impl Write, envelope: &OutboundEnvelope<'a>) -> io::Result<()> {
    let payload = rmp_serde::to_vec_named(envelope)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    let len: u32 = payload
        .len()
        .try_into()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "payload > u32::MAX"))?;

    w.write_all(&len.to_be_bytes())?;
    w.write_all(&payload)?;
    w.flush()
}

#[derive(serde::Serialize)]
struct OutboundEnvelope<'a> {
    id: u64,
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    response: Option<&'a Response>,
    #[serde(skip_serializing_if = "Option::is_none")]
    notification: Option<&'a Notification>,
}
