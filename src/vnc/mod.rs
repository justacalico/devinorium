//! Minimal VNC (RFB 3.8) client used by the machine-control endpoints.
//!
//! Each control call opens a short-lived connection: handshake, optional
//! VNC-auth (DES challenge-response), then either a full non-incremental
//! framebuffer fetch (screenshot) or a burst of pointer/key events. Only
//! the raw encoding is negotiated so decode stays trivial.

mod keysym;

use std::time::Duration;

use anyhow::{bail, Context};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

pub use keysym::{key_chord, text_keysym};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const IO_TIMEOUT: Duration = Duration::from_secs(15);
/// Guard against absurd ServerInit dimensions before allocating the canvas.
const MAX_FRAMEBUFFER_PIXELS: u32 = 64 * 1024 * 1024;

#[derive(Debug)]
pub struct ServerInfo {
    pub width: u16,
    pub height: u16,
    pub name: String,
}

pub struct VncClient {
    stream: TcpStream,
    pub info: ServerInfo,
}

async fn read_exact(stream: &mut TcpStream, buf: &mut [u8]) -> anyhow::Result<()> {
    tokio::time::timeout(IO_TIMEOUT, stream.read_exact(buf))
        .await
        .context("vnc read timed out")??;
    Ok(())
}

async fn write_all(stream: &mut TcpStream, buf: &[u8]) -> anyhow::Result<()> {
    tokio::time::timeout(IO_TIMEOUT, stream.write_all(buf))
        .await
        .context("vnc write timed out")??;
    Ok(())
}

/// The DES key for VNC auth: the password truncated/padded to 8 bytes with
/// each byte's bits reversed, per the RFB spec.
fn vnc_des_key(password: &str) -> [u8; 8] {
    let mut key = [0u8; 8];
    for (i, b) in password.as_bytes().iter().take(8).enumerate() {
        key[i] = b.reverse_bits();
    }
    key
}

fn vnc_auth_response(password: &str, challenge: &[u8; 16]) -> anyhow::Result<[u8; 16]> {
    use cipher::{BlockEncrypt, KeyInit};
    let cipher = des::Des::new_from_slice(&vnc_des_key(password))
        .map_err(|_| anyhow::anyhow!("invalid vnc key"))?;
    let mut out = [0u8; 16];
    cipher.encrypt_block_b2b(
        cipher::generic_array::GenericArray::from_slice(&challenge[..8]),
        cipher::generic_array::GenericArray::from_mut_slice(&mut out[..8]),
    );
    cipher.encrypt_block_b2b(
        cipher::generic_array::GenericArray::from_slice(&challenge[8..]),
        cipher::generic_array::GenericArray::from_mut_slice(&mut out[8..]),
    );
    Ok(out)
}

impl VncClient {
    /// Connect and complete the RFB handshake through ServerInit.
    pub async fn connect(host: &str, port: u16, password: &str) -> anyhow::Result<Self> {
        let addr = (host, port);
        let mut stream = tokio::time::timeout(CONNECT_TIMEOUT, TcpStream::connect(addr))
            .await
            .with_context(|| format!("connecting to {host}:{port} timed out"))?
            .with_context(|| format!("connecting to {host}:{port}"))?;

        let mut banner = [0u8; 12];
        read_exact(&mut stream, &mut banner).await?;
        if !banner.starts_with(b"RFB ") {
            bail!("not a VNC server");
        }
        write_all(&mut stream, b"RFB 003.008\n").await?;

        // Security types.
        let mut n_types = [0u8; 1];
        read_exact(&mut stream, &mut n_types).await?;
        if n_types[0] == 0 {
            // Connection failed; a reason string follows.
            let mut len = [0u8; 4];
            read_exact(&mut stream, &mut len).await?;
            let mut reason = vec![0u8; u32::from_be_bytes(len).min(4096) as usize];
            read_exact(&mut stream, &mut reason).await?;
            bail!(
                "vnc server refused connection: {}",
                String::from_utf8_lossy(&reason)
            );
        }
        let mut types = vec![0u8; n_types[0] as usize];
        read_exact(&mut stream, &mut types).await?;

        let want_auth = !password.is_empty();
        let chosen = if want_auth && types.contains(&2) {
            2u8
        } else if types.contains(&1) {
            1u8
        } else {
            bail!(
                "vnc server offers no usable security type (has {:?}, need {})",
                types,
                if want_auth { "vnc-auth" } else { "none" }
            );
        };
        write_all(&mut stream, &[chosen]).await?;

        if chosen == 2 {
            let mut challenge = [0u8; 16];
            read_exact(&mut stream, &mut challenge).await?;
            let response = vnc_auth_response(password, &challenge)?;
            write_all(&mut stream, &response).await?;
        }

        let mut result = [0u8; 4];
        read_exact(&mut stream, &mut result).await?;
        if u32::from_be_bytes(result) != 0 {
            bail!("vnc authentication failed");
        }

        // ClientInit (shared session), then ServerInit.
        write_all(&mut stream, &[1]).await?;
        let mut init = [0u8; 24];
        read_exact(&mut stream, &mut init).await?;
        let width = u16::from_be_bytes([init[0], init[1]]);
        let height = u16::from_be_bytes([init[2], init[3]]);
        if width == 0 || height == 0 {
            bail!("vnc server reported an empty framebuffer");
        }
        if width as u32 * height as u32 > MAX_FRAMEBUFFER_PIXELS {
            bail!("vnc framebuffer too large ({width}x{height})");
        }
        // init[4..20] is the server's pixel format; init[20..24] is the
        // desktop-name length, followed by that many name bytes. A name
        // past the cap is refused outright: reading only part of it would
        // leave the stream desynced for everything after.
        let name_len = u32::from_be_bytes([init[20], init[21], init[22], init[23]]);
        if name_len > 4096 {
            bail!("vnc desktop name too long ({name_len} bytes)");
        }
        let mut name = vec![0u8; name_len as usize];
        read_exact(&mut stream, &mut name).await?;

        // Ask for 32-bit true-colour (BGRX on the wire) and raw encoding
        // only, so framebuffer decode is a straight copy.
        let mut pixel_format = vec![0u8; 20];
        pixel_format[0] = 0; // SetPixelFormat
        pixel_format[4] = 32; // bits per pixel
        pixel_format[5] = 24; // depth
        pixel_format[6] = 0; // little-endian
        pixel_format[7] = 1; // true colour
        for (off, max) in [(8, 255u16), (10, 255), (12, 255)] {
            pixel_format[off..off + 2].copy_from_slice(&max.to_be_bytes());
        }
        pixel_format[14] = 16; // red shift
        pixel_format[15] = 8; // green shift
        pixel_format[16] = 0; // blue shift
        write_all(&mut stream, &pixel_format).await?;
        write_all(&mut stream, &[2, 0, 0, 1, 0, 0, 0, 0]).await?; // SetEncodings [raw]

        Ok(Self {
            stream,
            info: ServerInfo {
                width,
                height,
                name: String::from_utf8_lossy(&name).to_string(),
            },
        })
    }

    /// Fetch the full framebuffer and encode it as PNG.
    pub async fn screenshot(&mut self) -> anyhow::Result<Vec<u8>> {
        let (w, h) = (self.info.width, self.info.height);
        let mut req = [0u8; 10];
        req[0] = 3; // FramebufferUpdateRequest
        req[1] = 0; // non-incremental
        req[6..8].copy_from_slice(&w.to_be_bytes());
        req[8..10].copy_from_slice(&h.to_be_bytes());
        write_all(&mut self.stream, &req).await?;

        let mut canvas = vec![0u8; w as usize * h as usize * 4];
        loop {
            // Server messages carry different header sizes, so dispatch on
            // the type byte alone: Bell is a single byte and reading a fixed
            // header here would eat into the next message.
            let mut ty = [0u8; 1];
            read_exact(&mut self.stream, &mut ty).await?;
            match ty[0] {
                0 => {
                    let mut hdr = [0u8; 3]; // pad + rect count
                    read_exact(&mut self.stream, &mut hdr).await?;
                    let rects = u16::from_be_bytes([hdr[1], hdr[2]]);
                    self.read_update(&mut canvas, rects).await?;
                    return encode_png(&canvas, w as u32, h as u32);
                }
                1 => {
                    // SetColourMapEntries: pad + first-colour + u16 count,
                    // then count * 6 payload bytes.
                    let mut hdr = [0u8; 5];
                    read_exact(&mut self.stream, &mut hdr).await?;
                    let n = u16::from_be_bytes([hdr[3], hdr[4]]) as usize;
                    let mut skip = vec![0u8; n * 6];
                    read_exact(&mut self.stream, &mut skip).await?;
                }
                2 => {} // Bell carries no payload.
                3 => {
                    // ServerCutText: 3 pad bytes + u32 len + text. Refuse
                    // absurd lengths instead of half-draining them, which
                    // would desync every later message.
                    let mut tail = [0u8; 7];
                    read_exact(&mut self.stream, &mut tail).await?;
                    let n = u32::from_be_bytes([tail[3], tail[4], tail[5], tail[6]]);
                    if n > 8 * 1024 * 1024 {
                        bail!("vnc cut-text too large ({n} bytes)");
                    }
                    let mut skip = vec![0u8; n as usize];
                    read_exact(&mut self.stream, &mut skip).await?;
                }
                t => bail!("unexpected vnc server message type {t}"),
            }
        }
    }

    /// Apply the raw rectangles of one FramebufferUpdate to the canvas.
    async fn read_update(&mut self, canvas: &mut [u8], rects: u16) -> anyhow::Result<()> {
        let width = self.info.width as usize;
        // A full-frame update can never legitimately exceed the canvas; the
        // running total caps how much pixel data a server can make us read.
        let mut pixels_read = 0usize;
        for _ in 0..rects {
            let mut hdr = [0u8; 12];
            read_exact(&mut self.stream, &mut hdr).await?;
            let x = u16::from_be_bytes([hdr[0], hdr[1]]) as usize;
            let y = u16::from_be_bytes([hdr[2], hdr[3]]) as usize;
            let w = u16::from_be_bytes([hdr[4], hdr[5]]) as usize;
            let h = u16::from_be_bytes([hdr[6], hdr[7]]) as usize;
            let encoding = i32::from_be_bytes([hdr[8], hdr[9], hdr[10], hdr[11]]);
            if encoding != 0 {
                bail!("vnc server used unsupported encoding {encoding}");
            }
            if x.saturating_add(w) > width || y.saturating_add(h) > self.info.height as usize {
                bail!("vnc rectangle out of bounds");
            }
            pixels_read += w * h;
            if pixels_read > canvas.len() / 4 {
                bail!("vnc update exceeds the framebuffer");
            }
            let mut row = vec![0u8; w * 4];
            for row_idx in 0..h {
                read_exact(&mut self.stream, &mut row).await?;
                let dst = ((y + row_idx) * width + x) * 4;
                // Wire pixels are B,G,R,X (little-endian 32bpp, shifts
                // 16/8/0); the canvas holds RGBA.
                for i in 0..w {
                    let s = i * 4;
                    let d = dst + i * 4;
                    canvas[d] = row[s + 2];
                    canvas[d + 1] = row[s + 1];
                    canvas[d + 2] = row[s];
                    canvas[d + 3] = 255;
                }
            }
        }
        Ok(())
    }

    pub async fn pointer_event(&mut self, x: u16, y: u16, button_mask: u8) -> anyhow::Result<()> {
        let mut msg = [0u8; 6];
        msg[0] = 5;
        msg[1] = button_mask;
        msg[2..4].copy_from_slice(&x.to_be_bytes());
        msg[4..6].copy_from_slice(&y.to_be_bytes());
        write_all(&mut self.stream, &msg).await
    }

    pub async fn key_event(&mut self, keysym: u32, down: bool) -> anyhow::Result<()> {
        let mut msg = [0u8; 8];
        msg[0] = 4;
        msg[1] = u8::from(down);
        msg[4..8].copy_from_slice(&keysym.to_be_bytes());
        write_all(&mut self.stream, &msg).await
    }

    /// Press and release a key, holding any modifiers from the chord.
    pub async fn press_chord(&mut self, chord: &str) -> anyhow::Result<()> {
        let (mods, main) = key_chord(chord).ok_or_else(|| anyhow::anyhow!("unknown key"))?;
        for &m in &mods {
            self.key_event(m, true).await?;
        }
        self.key_event(main.0, true).await?;
        self.key_event(main.0, false).await?;
        for &m in mods.iter().rev() {
            self.key_event(m, false).await?;
        }
        Ok(())
    }

    /// Type a string one key at a time, holding shift where needed.
    pub async fn type_text(&mut self, text: &str) -> anyhow::Result<()> {
        for ch in text.chars() {
            let Some((sym, shift)) = text_keysym(ch) else {
                continue;
            };
            if shift {
                self.key_event(keysym::SHIFT_L, true).await?;
            }
            self.key_event(sym, true).await?;
            self.key_event(sym, false).await?;
            if shift {
                self.key_event(keysym::SHIFT_L, false).await?;
            }
        }
        Ok(())
    }
}

fn encode_png(rgba: &[u8], width: u32, height: u32) -> anyhow::Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header()?;
    writer.write_image_data(rgba)?;
    drop(writer);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::Mutex;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[test]
    fn vnc_key_reverses_password_bits() {
        // 'p' = 0x70 -> bits reversed 0x0E; 'a' = 0x61 -> 0x86.
        let key = vnc_des_key("password");
        assert_eq!(key[0], 0x70u8.reverse_bits());
        assert_eq!(key[1], 0x61u8.reverse_bits());
        let padded = vnc_des_key("ab");
        assert_eq!(&padded[2..], &[0u8; 6]);
    }

    #[test]
    fn vnc_auth_response_encrypts_challenge() {
        let challenge = [7u8; 16];
        let out = vnc_auth_response("secret", &challenge).unwrap();
        assert_eq!(out.len(), 16);
        assert_ne!(&out[..8], &challenge[..8]);
        // Deterministic: same input yields the same response.
        assert_eq!(vnc_auth_response("secret", &challenge).unwrap(), out);
        // A different password must not collide.
        assert_ne!(
            vnc_auth_response("other", &challenge).unwrap()[..8],
            out[..8]
        );
    }

    /// A scripted RFB 3.8 server: offers None+VNC-auth, verifies the DES
    /// response against `vnc_auth_response`, serves a solid-colour
    /// framebuffer, and records client input messages for assertions.
    struct FakeVnc {
        port: u16,
        events: Arc<Mutex<Vec<Vec<u8>>>>,
    }

    impl FakeVnc {
        async fn start(password: &'static str, width: u16, height: u16) -> Self {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let events = Arc::new(Mutex::new(Vec::new()));
            let ev = events.clone();
            tokio::spawn(async move {
                while let Ok((mut s, _)) = listener.accept().await {
                    let ev = ev.clone();
                    tokio::spawn(async move {
                        let _ = Self::conn(&mut s, password, width, height, ev).await;
                    });
                }
            });
            Self { port, events }
        }

        async fn conn(
            s: &mut TcpStream,
            password: &str,
            width: u16,
            height: u16,
            events: Arc<Mutex<Vec<Vec<u8>>>>,
        ) -> std::io::Result<()> {
            s.write_all(b"RFB 003.008\n").await?;
            let mut banner = [0u8; 12];
            s.read_exact(&mut banner).await?;
            s.write_all(&[2, 1, 2]).await?; // offer None and VNC auth
            let mut choice = [0u8; 1];
            s.read_exact(&mut choice).await?;
            if choice[0] == 2 {
                let challenge = [0xAB; 16];
                s.write_all(&challenge).await?;
                let mut resp = [0u8; 16];
                s.read_exact(&mut resp).await?;
                let ok = resp == vnc_auth_response(password, &challenge).unwrap();
                s.write_all(&(if ok { 0u32 } else { 1u32 }).to_be_bytes())
                    .await?;
                if !ok {
                    return Ok(());
                }
            } else {
                s.write_all(&0u32.to_be_bytes()).await?;
            }
            let mut init = [0u8; 1];
            s.read_exact(&mut init).await?;
            let mut server_init = Vec::with_capacity(24);
            server_init.extend_from_slice(&width.to_be_bytes());
            server_init.extend_from_slice(&height.to_be_bytes());
            server_init.extend_from_slice(&[0u8; 16]); // server pixel format
            server_init.extend_from_slice(&4u32.to_be_bytes());
            server_init.extend_from_slice(b"fake");
            s.write_all(&server_init).await?;

            loop {
                let mut ty = [0u8; 1];
                if s.read_exact(&mut ty).await.is_err() {
                    return Ok(());
                }
                match ty[0] {
                    0 => {
                        let mut rest = [0u8; 19];
                        s.read_exact(&mut rest).await?;
                    }
                    2 => {
                        let mut rest = [0u8; 3];
                        s.read_exact(&mut rest).await?;
                        let n = u16::from_be_bytes([rest[1], rest[2]]) as usize;
                        let mut skip = vec![0u8; n * 4];
                        s.read_exact(&mut skip).await?;
                    }
                    3 => {
                        let mut rest = [0u8; 9];
                        s.read_exact(&mut rest).await?;
                        let (x, y, w, h) = (
                            u16::from_be_bytes([rest[1], rest[2]]),
                            u16::from_be_bytes([rest[3], rest[4]]),
                            u16::from_be_bytes([rest[5], rest[6]]),
                            u16::from_be_bytes([rest[7], rest[8]]),
                        );
                        let mut msg = Vec::new();
                        msg.extend_from_slice(&[0, 0, 0, 1]); // type, pad, n_rects
                        msg.extend_from_slice(&x.to_be_bytes());
                        msg.extend_from_slice(&y.to_be_bytes());
                        msg.extend_from_slice(&w.to_be_bytes());
                        msg.extend_from_slice(&h.to_be_bytes());
                        msg.extend_from_slice(&0i32.to_be_bytes()); // raw
                                                                    // Solid red framebuffer: B,G,R,X.
                        for _ in 0..(w as usize * h as usize) {
                            msg.extend_from_slice(&[0, 0, 255, 0]);
                        }
                        s.write_all(&msg).await?;
                    }
                    4 => {
                        let mut rest = [0u8; 7];
                        s.read_exact(&mut rest).await?;
                        let mut m = vec![4u8];
                        m.extend_from_slice(&rest);
                        events.lock().unwrap().push(m);
                    }
                    5 => {
                        let mut rest = [0u8; 5];
                        s.read_exact(&mut rest).await?;
                        let mut m = vec![5u8];
                        m.extend_from_slice(&rest);
                        events.lock().unwrap().push(m);
                    }
                    6 => {
                        let mut rest = [0u8; 7];
                        s.read_exact(&mut rest).await?;
                        let n = u32::from_be_bytes([rest[3], rest[4], rest[5], rest[6]]) as usize;
                        let mut skip = vec![0u8; n.min(1024 * 1024)];
                        s.read_exact(&mut skip).await?;
                    }
                    _ => return Ok(()),
                }
            }
        }
    }

    #[tokio::test]
    async fn handshake_screenshot_and_input_against_fake_server() {
        let fake = FakeVnc::start("hunter2", 4, 2).await;
        let mut client = VncClient::connect("127.0.0.1", fake.port, "hunter2")
            .await
            .unwrap();
        assert_eq!((client.info.width, client.info.height), (4, 2));
        assert_eq!(client.info.name, "fake");

        let png = client.screenshot().await.unwrap();
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
        // Decode and check the solid-red pixels landed as RGBA.
        let decoder = png::Decoder::new(std::io::Cursor::new(&png));
        let mut reader = decoder.read_info().unwrap();
        let mut buf = vec![0u8; reader.output_buffer_size().unwrap()];
        let out = reader.next_frame(&mut buf).unwrap();
        assert_eq!((out.width, out.height), (4, 2));
        assert_eq!(&buf[..4], &[255, 0, 0, 255]);

        client.pointer_event(10, 20, 1).await.unwrap();
        client.press_chord("ctrl+c").await.unwrap();
        client.type_text("Hi").await.unwrap();
        drop(client);
        tokio::time::sleep(Duration::from_millis(50)).await;

        let events = fake.events.lock().unwrap().clone();
        let pointer = events.iter().filter(|e| e[0] == 5).count();
        assert_eq!(pointer, 1);
        let keys: Vec<u32> = events
            .iter()
            .filter(|e| e[0] == 4)
            .map(|e| u32::from_be_bytes([e[4], e[5], e[6], e[7]]))
            .collect();
        // ctrl+c: ctrl down, c down, c up, ctrl up. "Hi": shift down,
        // h down/up, shift up, i down/up.
        assert_eq!(
            keys,
            vec![
                0xFFE3, 'c' as u32, 'c' as u32, 0xFFE3, 0xFFE1, 'h' as u32, 'h' as u32, 0xFFE1,
                'i' as u32, 'i' as u32,
            ]
        );
    }

    #[tokio::test]
    async fn wrong_password_fails_auth() {
        let fake = FakeVnc::start("right", 4, 2).await;
        let err = VncClient::connect("127.0.0.1", fake.port, "wrong")
            .await
            .err()
            .expect("bad password should fail");
        assert!(err.to_string().contains("authentication failed"));
    }

    /// Run `script` on each accepted connection; returns the bound port.
    async fn scripted<F, Fut>(script: F) -> u16
    where
        F: Fn(TcpStream) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send,
    {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((s, _)) = listener.accept().await {
                script(s).await;
            }
        });
        port
    }

    /// Minimal 3.8 handshake with security type `sec` (1 = None), leaving
    /// the stream at ClientInit. Used by the malformed-server tests.
    async fn handshake(s: &mut TcpStream, sec: u8) -> std::io::Result<()> {
        s.write_all(b"RFB 003.008\n").await?;
        let mut banner = [0u8; 12];
        s.read_exact(&mut banner).await?;
        s.write_all(&[1, sec]).await?;
        let mut choice = [0u8; 1];
        s.read_exact(&mut choice).await?;
        s.write_all(&0u32.to_be_bytes()).await?;
        let mut init = [0u8; 1];
        s.read_exact(&mut init).await?;
        Ok(())
    }

    async fn send_server_init(s: &mut TcpStream, w: u16, h: u16) -> std::io::Result<()> {
        let mut out = Vec::new();
        out.extend_from_slice(&w.to_be_bytes());
        out.extend_from_slice(&h.to_be_bytes());
        out.extend_from_slice(&[0u8; 16]);
        out.extend_from_slice(&0u32.to_be_bytes());
        s.write_all(&out).await
    }

    /// Read the client's SetPixelFormat + SetEncodings + first
    /// FramebufferUpdateRequest, then return its rect.
    async fn read_fbur(s: &mut TcpStream) -> std::io::Result<(u16, u16, u16, u16)> {
        // SetPixelFormat(0) is 20 bytes, SetEncodings(2) is 4 + 4*n.
        let mut ty = [0u8; 1];
        s.read_exact(&mut ty).await?;
        let mut rest = [0u8; 19];
        s.read_exact(&mut rest).await?;
        s.read_exact(&mut ty).await?;
        let mut enc = [0u8; 3];
        s.read_exact(&mut enc).await?;
        let n = u16::from_be_bytes([enc[1], enc[2]]) as usize;
        let mut skip = vec![0u8; n * 4];
        s.read_exact(&mut skip).await?;
        s.read_exact(&mut ty).await?;
        // FramebufferUpdateRequest after the type byte: incremental, then
        // x, y, w, h.
        let mut req = [0u8; 9];
        s.read_exact(&mut req).await?;
        Ok((
            u16::from_be_bytes([req[1], req[2]]),
            u16::from_be_bytes([req[3], req[4]]),
            u16::from_be_bytes([req[5], req[6]]),
            u16::from_be_bytes([req[7], req[8]]),
        ))
    }

    /// Keep the socket open until the client hangs up, so tests that stop
    /// at ServerInit do not break the client's follow-up writes.
    async fn drain_until_eof(s: &mut TcpStream) {
        let mut buf = [0u8; 256];
        while s.read(&mut buf).await.unwrap_or(0) > 0 {}
    }

    #[tokio::test]
    async fn refused_connection_reports_reason() {
        let port = scripted(|mut s| async move {
            s.write_all(b"RFB 003.008\n").await.unwrap();
            let mut banner = [0u8; 12];
            s.read_exact(&mut banner).await.unwrap();
            s.write_all(&[0]).await.unwrap();
            s.write_all(&3u32.to_be_bytes()).await.unwrap();
            s.write_all(b"nah").await.unwrap();
        })
        .await;
        let err = VncClient::connect("127.0.0.1", port, "")
            .await
            .err()
            .expect("refused connection should fail");
        assert!(err.to_string().contains("nah"));
    }

    #[tokio::test]
    async fn password_set_but_server_only_offers_vncless_auth() {
        // Server offers only None while the machine has a password: the
        // client picks None rather than failing.
        let port = scripted(|mut s| async move {
            handshake(&mut s, 1).await.unwrap();
            send_server_init(&mut s, 4, 2).await.unwrap();
            drain_until_eof(&mut s).await;
        })
        .await;
        let client = VncClient::connect("127.0.0.1", port, "unused")
            .await
            .unwrap();
        assert_eq!(client.info.width, 4);
    }

    #[tokio::test]
    async fn no_usable_security_type_fails() {
        // Only VNC-auth offered but no password configured.
        let port = scripted(|mut s| async move {
            s.write_all(b"RFB 003.008\n").await.unwrap();
            let mut banner = [0u8; 12];
            s.read_exact(&mut banner).await.unwrap();
            s.write_all(&[1, 2]).await.unwrap();
        })
        .await;
        let err = VncClient::connect("127.0.0.1", port, "")
            .await
            .err()
            .expect("auth-only server with no password should fail");
        assert!(err.to_string().contains("no usable security type"));
    }

    #[tokio::test]
    async fn oversized_framebuffer_is_rejected() {
        let port = scripted(|mut s| async move {
            handshake(&mut s, 1).await.unwrap();
            send_server_init(&mut s, 65535, 65535).await.unwrap();
        })
        .await;
        let err = VncClient::connect("127.0.0.1", port, "")
            .await
            .err()
            .expect("absurd framebuffer should fail");
        assert!(err.to_string().contains("too large"));
    }

    #[tokio::test]
    async fn non_raw_encoding_is_rejected() {
        let port = scripted(|mut s| async move {
            handshake(&mut s, 1).await.unwrap();
            send_server_init(&mut s, 4, 2).await.unwrap();
            let (x, y, w, h) = read_fbur(&mut s).await.unwrap();
            let mut msg = Vec::new();
            msg.extend_from_slice(&[0, 0, 0, 1]);
            msg.extend_from_slice(&x.to_be_bytes());
            msg.extend_from_slice(&y.to_be_bytes());
            msg.extend_from_slice(&w.to_be_bytes());
            msg.extend_from_slice(&h.to_be_bytes());
            msg.extend_from_slice(&99i32.to_be_bytes()); // not raw
            s.write_all(&msg).await.unwrap();
        })
        .await;
        let mut client = VncClient::connect("127.0.0.1", port, "").await.unwrap();
        let err = client.screenshot().await.err().expect("should fail");
        assert!(err.to_string().contains("unsupported encoding"));
    }

    #[tokio::test]
    async fn out_of_bounds_rect_is_rejected() {
        let port = scripted(|mut s| async move {
            handshake(&mut s, 1).await.unwrap();
            send_server_init(&mut s, 4, 2).await.unwrap();
            read_fbur(&mut s).await.unwrap();
            let mut msg = Vec::new();
            msg.extend_from_slice(&[0, 0, 0, 1]);
            msg.extend_from_slice(&3u16.to_be_bytes()); // x
            msg.extend_from_slice(&0u16.to_be_bytes()); // y
            msg.extend_from_slice(&4u16.to_be_bytes()); // w: 3+4 > 4
            msg.extend_from_slice(&1u16.to_be_bytes()); // h
            msg.extend_from_slice(&0i32.to_be_bytes());
            s.write_all(&msg).await.unwrap();
        })
        .await;
        let mut client = VncClient::connect("127.0.0.1", port, "").await.unwrap();
        let err = client.screenshot().await.err().expect("should fail");
        assert!(err.to_string().contains("out of bounds"));
    }

    #[tokio::test]
    async fn colour_map_message_does_not_desync_the_stream() {
        // A SetColourMapEntries frame interleaved before the update must be
        // skipped cleanly: count is a u16 after the 4-byte header, followed
        // by count*6 payload bytes.
        let port = scripted(|mut s| async move {
            handshake(&mut s, 1).await.unwrap();
            send_server_init(&mut s, 4, 2).await.unwrap();
            let (x, y, w, h) = read_fbur(&mut s).await.unwrap();
            let mut msg = Vec::new();
            msg.extend_from_slice(&[1, 0]); // SCME: type + pad
            msg.extend_from_slice(&0u16.to_be_bytes()); // first colour
            msg.extend_from_slice(&2u16.to_be_bytes()); // count
            msg.extend_from_slice(&[0u8; 12]); // 2 * 6-byte entries
            msg.extend_from_slice(&[0, 0, 0, 1]); // FBU: 1 rect
            msg.extend_from_slice(&x.to_be_bytes());
            msg.extend_from_slice(&y.to_be_bytes());
            msg.extend_from_slice(&w.to_be_bytes());
            msg.extend_from_slice(&h.to_be_bytes());
            msg.extend_from_slice(&0i32.to_be_bytes());
            for _ in 0..(w as usize * h as usize) {
                msg.extend_from_slice(&[0, 0, 255, 0]);
            }
            s.write_all(&msg).await.unwrap();
        })
        .await;
        let mut client = VncClient::connect("127.0.0.1", port, "").await.unwrap();
        let png = client.screenshot().await.unwrap();
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
    }

    #[tokio::test]
    async fn bell_and_cut_text_do_not_desync_the_stream() {
        // Real servers interleave clipboard pushes and bells ahead of the
        // framebuffer update; both must be skipped by their exact wire size.
        let port = scripted(|mut s| async move {
            handshake(&mut s, 1).await.unwrap();
            send_server_init(&mut s, 4, 2).await.unwrap();
            let (x, y, w, h) = read_fbur(&mut s).await.unwrap();
            let mut msg = Vec::new();
            msg.push(2); // Bell: just the type byte
            msg.push(3); // ServerCutText: pad + len + text
            msg.extend_from_slice(&[0u8; 3]);
            msg.extend_from_slice(&3u32.to_be_bytes());
            msg.extend_from_slice(b"cop");
            msg.push(2); // another Bell
            msg.extend_from_slice(&[0, 0, 0, 1]); // FBU: 1 rect
            msg.extend_from_slice(&x.to_be_bytes());
            msg.extend_from_slice(&y.to_be_bytes());
            msg.extend_from_slice(&w.to_be_bytes());
            msg.extend_from_slice(&h.to_be_bytes());
            msg.extend_from_slice(&0i32.to_be_bytes());
            for _ in 0..(w as usize * h as usize) {
                msg.extend_from_slice(&[0, 0, 255, 0]);
            }
            s.write_all(&msg).await.unwrap();
        })
        .await;
        let mut client = VncClient::connect("127.0.0.1", port, "").await.unwrap();
        let png = client.screenshot().await.unwrap();
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
    }
}
