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

// The controlled PTY echoes the bytes we type, so every marker is written with
// a quote split (e.g. `__FP""START__`) in the command we send. The shell's own
// output has the halves joined (`__FPSTART__`); the echoed input line never
// does, so a search for the contiguous marker only ever matches real output.
// Output is delimited START..EXIT, so the echoed command and shell prompts fall
// outside and are excluded.
const MARK_START: &str = "__FPSTART__";
const MARK_EXIT: &str = "__FPEXIT__";
const MARK_END: &str = "__FPEND__";

fn is_windows(platform: &str) -> bool {
    platform.to_lowercase().contains("windows")
}

/// Sent first (before framing) to quiet the interactive shell: turn off tty
/// input echo and blank the prompt, so only real command output remains
/// between the markers. Must be processed before the framed command is sent,
/// because the tty line discipline echoes earlier input at the kernel layer.
fn quiet_shell(platform: &str) -> String {
    if is_windows(platform) {
        "function prompt { '' }\r\n".to_owned()
    } else {
        "stty -echo 2>/dev/null; export PS1='' PS2='' PROMPT_COMMAND=''\n".to_owned()
    }
}

/// The framed command: START marker, the command, then the EXIT marker with the
/// exit status. Markers are quote-split so an echoed copy can never match the
/// joined form we scan for.
fn marker_command(command: &str, platform: &str) -> String {
    if is_windows(platform) {
        format!(
            "Write-Output (\"__FP\"+\"START__\"); {command}; Write-Output (\"__FP\"+\"EXIT__\"+$LASTEXITCODE+\"__FP\"+\"END__\")\r\n"
        )
    } else {
        format!(
            "echo \"__FP\"\"START__\"; {command}\necho \"__FP\"\"EXIT__$?__FP\"\"END__\"\n"
        )
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

/// Extract the command output delimited by the joined START and EXIT markers,
/// so the echoed command and shell prompts (outside the markers) are excluded.
fn clean_output(raw: &str) -> String {
    let body = match (raw.find(MARK_START), raw.find(MARK_EXIT)) {
        (Some(s), Some(e)) if s < e => {
            let after_start = raw[s..].find('\n').map(|n| s + n + 1).unwrap_or(e);
            &raw[after_start.min(e)..e]
        }
        // START marker missing: fall back to everything before EXIT.
        (_, Some(e)) => &raw[..e],
        _ => raw,
    };
    // PTYs emit CRLF; normalize to LF for clean agent-facing text.
    body.replace("\r\n", "\n").trim_matches(['\r', '\n']).to_owned()
}

fn parse_exit(raw: &str) -> Option<i32> {
    let start = raw.find(MARK_EXIT)? + MARK_EXIT.len();
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

    // Wait for the shell to open.
    let terminal_id = loop {
        let Some(msg) = session.next_message().await? else {
            bail!("no response opening terminal on {id}");
        };
        if let Some(message::Union::TerminalResponse(resp)) = msg.union {
            match resp.union {
                Some(terminal_response::Union::Opened(o)) => {
                    if !o.success {
                        bail!("terminal refused on {id}: {}", o.message);
                    }
                    break o.terminal_id;
                }
                Some(terminal_response::Union::Error(e)) => {
                    bail!("terminal error on {id}: {}", e.message);
                }
                _ => {}
            }
        }
    };

    // Quiet the shell, then let the tty line discipline apply it before framing.
    session
        .send(terminal_data(terminal_id, &quiet_shell(&platform)))
        .await?;
    hbb_common::tokio::time::sleep(Duration::from_millis(400)).await;
    session
        .send(terminal_data(terminal_id, &marker_command(command, &platform)))
        .await?;

    let mut raw = String::new();
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline {
        let Some(msg) = session.next_message().await? else {
            continue; // idle read gap; keep waiting for the marker until deadline
        };
        let Some(message::Union::TerminalResponse(resp)) = msg.union else {
            continue;
        };
        match resp.union {
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
            _ => {}
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
