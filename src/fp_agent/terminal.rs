use std::time::{Duration, Instant};

use hbb_common::{bail, compress, log, rendezvous_proto::ConnType, ResultType};
use base::message_proto::*;

use super::session::connect_and_login;

/// What a command run in the remote terminal produced.
pub struct TerminalRun {
    pub output: String,
    pub exit_code: i32,
    pub platform: String,
}

// The controlled PTY echoes the bytes we type, so the exit marker is written
// with a quote split (`__FP""EXIT__`) in the command we send. The shell's own
// output has the halves joined (`__FPEXIT__`); the echoed input line never
// does, so a search for the contiguous marker only ever matches real output.
const MARK_START: &str = "__FPEXIT__";
const MARK_END: &str = "__FPEND__";

fn marker_command(command: &str, platform: &str) -> String {
    if platform.to_lowercase().contains("windows") {
        // Default Windows shell is PowerShell; $LASTEXITCODE is best-effort.
        format!(
            "{command}\r\nWrite-Output (\"__FP\"+\"EXIT__\"+$LASTEXITCODE+\"__FP\"+\"END__\")\r\n"
        )
    } else {
        format!("{command}\necho \"__FP\"\"EXIT__$?__FP\"\"END__\"\n")
    }
}

fn terminal_data(terminal_id: i32, text: &str) -> Message {
    let mut action = TerminalAction::new();
    action.set_data(TerminalData {
        terminal_id,
        data: bytes::Bytes::from(text.as_bytes().to_vec()),
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_terminal_action(action);
    msg
}

fn open_terminal(rows: u32, cols: u32) -> Message {
    let mut action = TerminalAction::new();
    action.set_open(OpenTerminal {
        terminal_id: 0,
        rows,
        cols,
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_terminal_action(action);
    msg
}

fn close_terminal(terminal_id: i32) -> Message {
    let mut action = TerminalAction::new();
    action.set_close(CloseTerminal {
        terminal_id,
        ..Default::default()
    });
    let mut msg = Message::new();
    msg.set_terminal_action(action);
    msg
}

fn decode(data: &[u8], compressed: bool) -> Vec<u8> {
    if compressed {
        compress::decompress(data)
    } else {
        data.to_vec()
    }
}

/// Strip the echoed command line (the one still carrying the split marker) and
/// everything from the joined marker onward, leaving just the command output.
fn clean_output(raw: &str) -> String {
    let cut = raw.find(MARK_START).map(|i| &raw[..i]).unwrap_or(raw);
    let mut lines: Vec<&str> = cut.lines().collect();
    lines.retain(|l| !l.contains("__FP\"\"EXIT__") && !l.contains("\"__FP\"+\"EXIT__\""));
    let mut out = lines.join("\n");
    while out.ends_with('\n') || out.ends_with('\r') {
        out.pop();
    }
    out.trim_start_matches(['\r', '\n']).to_owned()
}

fn parse_exit(raw: &str) -> Option<i32> {
    let start = raw.find(MARK_START)? + MARK_START.len();
    let rest = &raw[start..];
    let end = rest.find(MARK_END)?;
    rest[..end].trim().parse::<i32>().ok()
}

/// Open a terminal on `id`, run one command, and return its output and exit
/// code. The remote shell session is closed before returning.
pub async fn run_command(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    command: &str,
) -> ResultType<TerminalRun> {
    let mut session = connect_and_login(key, token, id, password, ConnType::TERMINAL).await?;
    let platform = session.platform();

    session.send(open_terminal(24, 200)).await?;

    let mut terminal_id = 0;
    let mut opened = false;
    let mut sent_command = false;
    let mut raw = String::new();
    let deadline = Instant::now() + Duration::from_secs(60);

    while Instant::now() < deadline {
        let Some(msg) = session.next_message().await? else {
            if opened {
                // Idle gap after output with no marker yet: keep waiting until deadline.
                continue;
            }
            bail!("no response opening terminal on {id}");
        };
        let Some(message::Union::TerminalResponse(resp)) = msg.union else {
            continue;
        };
        match resp.union {
            Some(terminal_response::Union::Opened(o)) => {
                if !o.success {
                    bail!("terminal refused on {id}: {}", o.message);
                }
                terminal_id = o.terminal_id;
                opened = true;
                if !sent_command {
                    session
                        .send(terminal_data(terminal_id, &marker_command(command, &platform)))
                        .await?;
                    sent_command = true;
                }
            }
            Some(terminal_response::Union::Data(d)) => {
                raw.push_str(&String::from_utf8_lossy(&decode(&d.data, d.compressed)));
                if parse_exit(&raw).is_some() {
                    break;
                }
            }
            Some(terminal_response::Union::Closed(c)) => {
                log::debug!("terminal {} closed, exit {}", c.terminal_id, c.exit_code);
                break;
            }
            Some(terminal_response::Union::Error(e)) => {
                bail!("terminal error on {id}: {}", e.message);
            }
            None => {}
        }
    }

    let _ = session.send(close_terminal(terminal_id)).await;

    let Some(exit_code) = parse_exit(&raw) else {
        bail!(
            "command did not complete within timeout; captured {} bytes",
            raw.len()
        );
    };
    Ok(TerminalRun {
        output: clean_output(&raw),
        exit_code,
        platform,
    })
}
