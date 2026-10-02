//! Minimal HTTP/1.1 client for the native-mls v2 relay (plain http, LAN/CI).
//!
//! std-only on purpose: no TLS client in the dependency graph (the relay is an
//! intranet service behind the operator's network), and CI stays reproducible
//! with a tiny Cargo.lock. Each request opens its own connection and sends
//! `Connection: close`, so response framing is "header block, then body to
//! EOF" — with a chunked-decoding fallback if a proxy intervenes.

use std::io::{Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

/// Review 2 B-M4: a relay that stops answering must not block the poll loop
/// forever (the session deadline runs on the same thread), and a response
/// is bounded — the largest legitimate page is 2,000 events of ≤1 MiB.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);
const READ_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_RESPONSE_BYTES: u64 = 256 << 20;

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

#[derive(Debug)]
pub enum HttpError {
    Io(std::io::Error),
    BadUrl,
    BadResponse(&'static str),
}

impl std::fmt::Display for HttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HttpError::Io(e) => write!(f, "io error: {e}"),
            HttpError::BadUrl => write!(f, "base url must be http://host:port"),
            HttpError::BadResponse(why) => write!(f, "bad relay response: {why}"),
        }
    }
}

impl From<std::io::Error> for HttpError {
    fn from(e: std::io::Error) -> Self { HttpError::Io(e) }
}

/// `base` is `http://host:port`; `path_qs` starts with `/`; `extra_headers`
/// are emitted verbatim after `Host` (caller auth injects the CF Access
/// assertion this way, review C1 fallback path).
pub fn request(
    base: &str,
    method: &str,
    path_qs: &str,
    body: Option<&[u8]>,
    extra_headers: &[(&str, &str)],
) -> Result<Response, HttpError> {
    let (host, port) = split_base(base)?;
    // Header injection guard: CR/LF in a value would smuggle a second header
    // (or request) — validate before any socket is opened.
    let mut headers_block = String::new();
    for (name, value) in extra_headers {
        if name.is_empty() || value.is_empty()
            || name.chars().any(|c| c == '\r' || c == '\n' || c == ':')
            || value.chars().any(|c| c == '\r' || c == '\n')
        {
            return Err(HttpError::BadUrl);
        }
        headers_block.push_str(&format!("{name}: {value}\r\n"));
    }
    let addr = (host, port)
        .to_socket_addrs()?
        .next()
        .ok_or(HttpError::BadUrl)?;
    let stream = TcpStream::connect_timeout(&addr, CONNECT_TIMEOUT)?;
    stream.set_write_timeout(Some(WRITE_TIMEOUT))?;
    stream.set_read_timeout(Some(READ_TIMEOUT))?;
    let mut stream = stream;
    let mut req = format!("{method} {path_qs} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n");
    req.push_str(&headers_block);
    match body {
        Some(bytes) => {
            req.push_str("Content-Type: application/json\r\n");
            req.push_str(&format!("Content-Length: {}\r\n", bytes.len()));
        }
        None => req.push_str("Content-Length: 0\r\n"),
    }
    req.push_str("\r\n");
    stream.write_all(req.as_bytes())?;
    if let Some(bytes) = body { stream.write_all(bytes)?; }
    stream.flush()?;

    let mut raw = Vec::new();
    (&mut stream).take(MAX_RESPONSE_BYTES + 1).read_to_end(&mut raw)?;
    if raw.len() as u64 > MAX_RESPONSE_BYTES {
        return Err(HttpError::BadResponse("response exceeds the size limit"));
    }

    let header_end = find_header_end(&raw).ok_or(HttpError::BadResponse("no header terminator"))?;
    let head = std::str::from_utf8(&raw[..header_end]).map_err(|_| HttpError::BadResponse("non-utf8 headers"))?;
    let mut lines = head.split("\r\n");
    let status_line = lines.next().ok_or(HttpError::BadResponse("empty response"))?;
    let status = status_line
        .split_whitespace()
        .nth(1)
        .and_then(|code| code.parse::<u16>().ok())
        .ok_or(HttpError::BadResponse("unreadable status line"))?;
    let mut chunked = false;
    for line in lines {
        let (name, value) = line.split_once(':').ok_or(HttpError::BadResponse("bad header line"))?;
        if name.trim().eq_ignore_ascii_case("transfer-encoding")
            && value.trim().eq_ignore_ascii_case("chunked")
        {
            chunked = true;
        }
    }
    let rest = &raw[header_end + 4..];
    let body = if chunked { decode_chunked(rest)? } else { rest.to_vec() };
    Ok(Response { status, body })
}

fn split_base(base: &str) -> Result<(&str, u16), HttpError> {
    let rest = base.strip_prefix("http://").ok_or(HttpError::BadUrl)?;
    let rest = rest.trim_end_matches('/');
    if rest.is_empty() || rest.contains('/') {
        return Err(HttpError::BadUrl);
    }
    // `[::1]:port` (review 2 L4): a bracketed IPv6 literal carries colons of
    // its own, so the port split happens after the closing bracket.
    if let Some(inner) = rest.strip_prefix('[') {
        let (host, after) = inner.split_once(']').ok_or(HttpError::BadUrl)?;
        return match after.strip_prefix(':') {
            Some(port) => Ok((host, port.parse::<u16>().map_err(|_| HttpError::BadUrl)?)),
            None if after.is_empty() => Ok((host, 80)),
            None => Err(HttpError::BadUrl),
        };
    }
    match rest.rsplit_once(':') {
        Some((host, port)) => Ok((host, port.parse::<u16>().map_err(|_| HttpError::BadUrl)?)),
        None => Ok((rest, 80)),
    }
}

fn find_header_end(raw: &[u8]) -> Option<usize> {
    raw.windows(4).position(|w| w == b"\r\n\r\n")
}

fn decode_chunked(mut rest: &[u8]) -> Result<Vec<u8>, HttpError> {
    let mut out = Vec::new();
    loop {
        let line_end = rest
            .windows(2)
            .position(|w| w == b"\r\n")
            .ok_or(HttpError::BadResponse("unterminated chunk size"))?;
        let size_text = std::str::from_utf8(&rest[..line_end])
            .map_err(|_| HttpError::BadResponse("non-utf8 chunk size"))?;
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16)
            .map_err(|_| HttpError::BadResponse("bad chunk size"))?;
        rest = &rest[line_end + 2..];
        if size == 0 { return Ok(out); }
        // review 2 L1: an absurd chunk size must not overflow the bound check.
        let needed = size.checked_add(2).ok_or(HttpError::BadResponse("bad chunk size"))?;
        if rest.len() < needed { return Err(HttpError::BadResponse("truncated chunk")); }
        out.extend_from_slice(&rest[..size]);
        rest = &rest[needed..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    /// Read until the request header terminator — the client keeps its write
    /// side open (no half-close), so reading to EOF would deadlock.
    fn read_request(stream: &mut std::net::TcpStream) -> String {
        let mut raw = Vec::new();
        let mut buf = [0u8; 1024];
        while !raw.windows(4).any(|w| w == b"\r\n\r\n") {
            let n = stream.read(&mut buf).expect("read request");
            assert!(n > 0, "eof before header terminator");
            raw.extend_from_slice(&buf[..n]);
        }
        String::from_utf8(raw).expect("utf8 request")
    }

    fn respond(stream: &mut std::net::TcpStream) {
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
            .expect("write response");
    }

    /// The auth header must reach the wire verbatim, and a CR/LF smuggle in a
    /// header value must be rejected before anything is written.
    #[test]
    fn extra_headers_reach_the_wire_and_injection_is_rejected() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let addr = listener.local_addr().expect("addr");
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let text = read_request(&mut stream);
            assert!(text.contains("Cf-Access-Jwt-Assertion: tok-1\r\n"), "header missing: {text}");
            respond(&mut stream);
        });
        let resp = request(
            &format!("http://127.0.0.1:{}", addr.port()),
            "GET",
            "/v2/health",
            None,
            &[("Cf-Access-Jwt-Assertion", "tok-1")],
        )
        .expect("request");
        assert_eq!(resp.status, 200);
        assert_eq!(resp.body, b"{\"ok\":true}");
        server.join().expect("server thread");

        // A header value with CRLF must be refused before any socket is
        // opened — nothing is listening here, so a connect attempt would
        // surface as an io error instead of the injection rejection.
        let err = request("http://127.0.0.1:1", "GET", "/v2/health", None, &[("X-Bad", "v\r\nX: 1")]);
        assert!(matches!(err, Err(HttpError::BadUrl)));
    }
}
