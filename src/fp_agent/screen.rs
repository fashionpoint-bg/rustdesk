//! Screen tools: one screenshot, mouse and keyboard on the peer's display.
//! The last resort for the agent: clinic screens show patient data, so the MCP
//! layer requires a reason for every call and the terminal/files come first.

use std::{
    path::Path,
    time::{Duration, Instant},
};

use hbb_common::{bail, rendezvous_proto::ConnType, sleep, ResultType};
use base::message_proto::*;

use crate::common::input::{
    MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_TYPE_DOWN, MOUSE_TYPE_MOVE, MOUSE_TYPE_UP,
    MOUSE_TYPE_WHEEL,
};

use super::session::{connect_and_login, Session};

/// A screenshot as the peer encoded it.
pub struct Shot {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Width and height from a PNG's IHDR chunk.
fn png_size(png: &[u8]) -> Option<(u32, u32)> {
    if png.len() < 24 || &png[..8] != b"\x89PNG\r\n\x1a\n" || &png[12..16] != b"IHDR" {
        return None;
    }
    let w = u32::from_be_bytes(png[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(png[20..24].try_into().ok()?);
    Some((w, h))
}

/// Take one screenshot of `display` (0 = primary). The peer captures the frame
/// and encodes it as PNG itself; the video frames that stream meanwhile are
/// dropped unread.
pub async fn screenshot(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    display: i32,
) -> ResultType<Shot> {
    let mut session = connect_and_login(key, token, id, password, ConnType::DEFAULT_CONN).await?;
    let mut req = ScreenshotRequest::new();
    req.display = display;
    req.sid = "fpremote-agent".to_owned();
    let mut msg = Message::new();
    msg.set_screenshot_request(req);
    session.send(msg).await?;

    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if Instant::now() >= deadline {
            bail!("no screenshot from {id} within 30s");
        }
        let Some(msg) = session.next_message().await? else {
            continue;
        };
        if let Some(message::Union::ScreenshotResponse(r)) = msg.union {
            if !r.msg.is_empty() {
                bail!("screenshot on {id}: {}", r.msg);
            }
            let png = r.data.to_vec();
            let Some((width, height)) = png_size(&png) else {
                bail!("screenshot on {id}: the peer did not send a PNG");
            };
            return Ok(Shot { png, width, height });
        }
    }
}

/// Write a screenshot to `out` and return it.
pub async fn screenshot_to_file(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    display: i32,
    out: &Path,
) -> ResultType<Shot> {
    let shot = screenshot(key, token, id, password, display).await?;
    if let Some(parent) = out.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(out, &shot.png)?;
    Ok(shot)
}

/// What the mouse should do. Coordinates are pixels in the display's own
/// screenshot (top-left = 0,0).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MouseAction {
    Move,
    Click,
    DoubleClick,
    RightClick,
    /// Wheel by `dy` notches (positive = up/away from the user).
    Scroll(i32),
}

impl MouseAction {
    pub fn parse(name: &str, dy: i32) -> ResultType<Self> {
        Ok(match name {
            "move" => Self::Move,
            "click" => Self::Click,
            "double_click" => Self::DoubleClick,
            "right_click" => Self::RightClick,
            "scroll" => {
                if dy == 0 {
                    bail!("scroll needs a non-zero dy");
                }
                Self::Scroll(dy)
            }
            other => bail!(
                "unknown mouse action {other}; use move, click, double_click, right_click or scroll"
            ),
        })
    }
}

fn mouse_msg(mask: i32, x: i32, y: i32) -> Message {
    let mut msg = Message::new();
    msg.set_mouse_event(MouseEvent {
        mask,
        x,
        y,
        ..Default::default()
    });
    msg
}

/// The display's origin in the peer's virtual desktop, from the login PeerInfo.
fn display_origin(session: &Session, display: i32) -> ResultType<(i32, i32)> {
    let displays = session.displays();
    let Some(d) = displays.get(display.max(0) as usize) else {
        bail!("display {display} does not exist (the peer has {})", displays.len());
    };
    Ok((d.x, d.y))
}

/// Run one mouse action on the peer.
pub async fn mouse(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    display: i32,
    action: MouseAction,
    x: i32,
    y: i32,
) -> ResultType<()> {
    let mut session = connect_and_login(key, token, id, password, ConnType::DEFAULT_CONN).await?;
    let (ox, oy) = display_origin(&session, display)?;
    let (ax, ay) = (ox + x, oy + y);

    let mut msgs = vec![mouse_msg(MOUSE_TYPE_MOVE, ax, ay)];
    let click = |button: i32, msgs: &mut Vec<Message>| {
        msgs.push(mouse_msg((button << 3) | MOUSE_TYPE_DOWN, ax, ay));
        msgs.push(mouse_msg((button << 3) | MOUSE_TYPE_UP, ax, ay));
    };
    match action {
        MouseAction::Move => {}
        MouseAction::Click => click(MOUSE_BUTTON_LEFT, &mut msgs),
        MouseAction::DoubleClick => {
            click(MOUSE_BUTTON_LEFT, &mut msgs);
            click(MOUSE_BUTTON_LEFT, &mut msgs);
        }
        MouseAction::RightClick => click(MOUSE_BUTTON_RIGHT, &mut msgs),
        MouseAction::Scroll(dy) => msgs.push(mouse_msg(MOUSE_TYPE_WHEEL, 0, dy)),
    }
    for m in msgs {
        session.send(m).await?;
        sleep(0.05).await;
    }
    // Let the peer apply the events before the connection closes.
    sleep(0.5).await;
    Ok(())
}

fn control_key(name: &str) -> Option<ControlKey> {
    Some(match name {
        "enter" | "return" => ControlKey::Return,
        "tab" => ControlKey::Tab,
        "esc" | "escape" => ControlKey::Escape,
        "backspace" => ControlKey::Backspace,
        "delete" | "del" => ControlKey::Delete,
        "insert" => ControlKey::Insert,
        "space" => ControlKey::Space,
        "up" => ControlKey::UpArrow,
        "down" => ControlKey::DownArrow,
        "left" => ControlKey::LeftArrow,
        "right" => ControlKey::RightArrow,
        "home" => ControlKey::Home,
        "end" => ControlKey::End,
        "pageup" => ControlKey::PageUp,
        "pagedown" => ControlKey::PageDown,
        "f1" => ControlKey::F1,
        "f2" => ControlKey::F2,
        "f3" => ControlKey::F3,
        "f4" => ControlKey::F4,
        "f5" => ControlKey::F5,
        "f6" => ControlKey::F6,
        "f7" => ControlKey::F7,
        "f8" => ControlKey::F8,
        "f9" => ControlKey::F9,
        "f10" => ControlKey::F10,
        "f11" => ControlKey::F11,
        "f12" => ControlKey::F12,
        "ctrl+alt+del" | "ctrl+alt+delete" => ControlKey::CtrlAltDel,
        _ => return None,
    })
}

fn modifier(name: &str) -> Option<ControlKey> {
    Some(match name {
        "ctrl" | "control" => ControlKey::Control,
        "alt" => ControlKey::Alt,
        "shift" => ControlKey::Shift,
        "meta" | "win" | "super" | "cmd" => ControlKey::Meta,
        _ => return None,
    })
}

/// Build the key event for a key name or combination such as `enter`, `f5`,
/// `ctrl+c`, `alt+f4`, `ctrl+shift+esc`.
fn key_event(combo: &str) -> ResultType<KeyEvent> {
    let lower = combo.trim().to_lowercase();
    let mut evt = KeyEvent {
        press: true,
        mode: KeyboardMode::Legacy.into(),
        ..Default::default()
    };
    if let Some(ck) = control_key(&lower) {
        evt.set_control_key(ck);
        return Ok(evt);
    }
    let parts: Vec<&str> = lower.split('+').map(str::trim).collect();
    let (last, mods) = parts.split_last().ok_or_else(|| hbb_common::anyhow::anyhow!("empty key"))?;
    for m in mods {
        let Some(mk) = modifier(m) else {
            bail!("unknown modifier {m} in {combo}; use ctrl, alt, shift or meta");
        };
        evt.modifiers.push(mk.into());
    }
    if let Some(ck) = control_key(last) {
        evt.set_control_key(ck);
    } else {
        let mut chars = last.chars();
        match (chars.next(), chars.next()) {
            (Some(c), None) => evt.set_chr(c as u32),
            _ => bail!("unknown key {last} in {combo}"),
        }
    }
    Ok(evt)
}

/// What to do with the keyboard: type text as-is, or press one key/combination.
pub enum KeyboardAction<'a> {
    Type(&'a str),
    Press(&'a str),
}

/// Type text or press a key on the peer.
pub async fn keyboard(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    action: KeyboardAction<'_>,
) -> ResultType<()> {
    let evt = match action {
        KeyboardAction::Type(text) => {
            if text.is_empty() {
                bail!("nothing to type");
            }
            let mut evt = KeyEvent {
                press: true,
                mode: KeyboardMode::Legacy.into(),
                ..Default::default()
            };
            evt.set_seq(text.to_owned());
            evt
        }
        KeyboardAction::Press(combo) => key_event(combo)?,
    };
    let mut session = connect_and_login(key, token, id, password, ConnType::DEFAULT_CONN).await?;
    let mut msg = Message::new();
    msg.set_key_event(evt);
    session.send(msg).await?;
    // Let the peer apply the input before the connection closes.
    sleep(0.5).await;
    Ok(())
}
