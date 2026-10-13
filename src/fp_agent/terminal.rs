use std::{
    fmt::Write as _,
    time::{Duration, Instant},
};

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
/// Pagers go to `cat`: on a terminal `git log`, `systemctl` and `man` open
/// `less`, which waits for a key until the call times out.
fn quiet_shell(platform: &str) -> String {
    if is_windows(platform) {
        "function prompt { '' }\r\n".to_owned()
    } else {
        "stty -echo 2>/dev/null; export PS1='' PS2='' PROMPT_COMMAND='' PAGER=cat GIT_PAGER=cat SYSTEMD_PAGER=cat MANPAGER=cat\n".to_owned()
    }
}

/// Every line typed into a POSIX shell stays under the 4096-byte line limit of
/// a terminal in canonical mode (a shell without a line editor, such as dash).
const POSIX_CHUNK: usize = 3000;
/// Length of each base64 line typed into PowerShell.
const PS_CHUNK: usize = 2000;

/// POSIX run line. `$__fp` holds the command as `\0NNN` octal escapes;
/// `printf %b` turns them back into the command, which runs with `eval` in a
/// subshell with stdin from /dev/null: `exit` ends only the subshell, so its
/// status still reaches the EXIT marker, and a command that reads input gets
/// end of file instead of waiting for a key.
const POSIX_RUN: &str = r#"echo "__FP""START__"; ( eval "$(printf '%b' "$__fp")" ) </dev/null; echo "__FP""EXIT__$?__FP""END__""#;

/// Appended to the PowerShell command inside the encoded script, so `$?` is
/// read right after the command's own last statement (after Invoke-Expression
/// it only says that Invoke-Expression ran).
const PS_STATUS: &str = "\n$__fpok=$?; $__fpec=$LASTEXITCODE";

/// PowerShell run line. `$__fps` holds the script as base64; it runs with
/// Invoke-Expression in try/catch, because a terminating error (`throw`,
/// `-ErrorAction Stop`, a parse error) would otherwise drop the rest of the
/// line, EXIT marker included; a caught error is printed and counts as a
/// failure. `$LASTEXITCODE` is set only by native programs, so the status is
/// 0 when the last statement succeeded, else the native exit code, else 1.
/// `exit` in PowerShell ends the shell itself; the call then fails at once,
/// with the output so far.
const PS_RUN: &str = r#"Write-Output ("__FP"+"START__"); $__fpt=$false; $__fpok=$false; $__fpec=$null; try { Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($__fps))) } catch { $__fpt=$true; Write-Output ($_ | Out-String) }; Write-Output ("__FP"+"EXIT__"+$(if($__fpt){1}elseif($__fpok){0}elseif($null -ne $__fpec -and $__fpec -ne 0){$__fpec}else{1})+"__FP"+"END__")"#;

/// The command as the lines typed into the shell: assignments that carry it
/// encoded, then the run line, which prints the START marker, runs it and
/// prints the EXIT marker with its status. The shell's line editor never sees
/// the command itself; typed as it is, it was open to history expansion (`!`),
/// tab completion, and an unbalanced quote or bracket waiting for more input
/// until the call timed out. Markers are quote-split so an echoed copy can
/// never match the joined form we scan for.
fn framed_command(command: &str, platform: &str) -> String {
    if is_windows(platform) {
        let script = format!("{command}{PS_STATUS}");
        let b64 = hbb_common::sodiumoxide::base64::encode(
            script.as_bytes(),
            hbb_common::sodiumoxide::base64::Variant::Original,
        );
        let mut lines = assign_lines(&b64, PS_CHUNK, "$__fps='", "$__fps+='");
        lines.push(PS_RUN.to_owned());
        lines.join("\r\n") + "\r\n"
    } else {
        let mut octal = String::with_capacity(command.len() * 5);
        for b in command.bytes() {
            let _ = write!(octal, "\\0{b:03o}");
        }
        let mut lines = assign_lines(&octal, POSIX_CHUNK, "__fp='", "__fp=\"$__fp\"'");
        lines.push(POSIX_RUN.to_owned());
        lines.join("\n") + "\n"
    }
}

/// Split an ASCII payload into single-quoted shell assignments: the first line
/// assigns, the rest append. An empty payload still assigns an empty value.
fn assign_lines(payload: &str, size: usize, first: &str, next: &str) -> Vec<String> {
    let mut lines = Vec::new();
    let mut start = 0;
    loop {
        let end = (start + size).min(payload.len());
        let prefix = if start == 0 { first } else { next };
        lines.push(format!("{prefix}{}'", &payload[start..end]));
        start = end;
        if start >= payload.len() {
            break;
        }
    }
    lines
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

/// Drop terminal escape sequences, so the agent gets plain text: colours
/// (`ESC[01;31m`), the bracketed-paste toggles bash prints around each prompt
/// (`ESC[?2004h`, `ESC[?2004l`), cursor movement and window titles.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        match chars.next() {
            // CSI: parameter and intermediate bytes up to one final byte @..~
            Some('[') => {
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            // OSC: up to BEL or ST (ESC \)
            Some(']') => {
                while let Some(c) = chars.next() {
                    if c == '\x07' {
                        break;
                    }
                    if c == '\x1b' && chars.peek() == Some(&'\\') {
                        chars.next();
                        break;
                    }
                }
            }
            // ESC, intermediate byte, final byte (`ESC ( B`)
            Some(c) if (' '..='/').contains(&c) => {
                chars.next();
            }
            // Any other escape is ESC plus one character.
            _ => {}
        }
    }
    out
}

/// Keep what a terminal shows of each line: a carriage return goes back to the
/// start of the line and the text after it overwrites, which is how progress
/// meters (apt, curl, dd) redraw themselves. A carriage return at the end of a
/// line is only a line ending and is dropped.
fn collapse_cr(s: &str) -> String {
    s.split('\n')
        .map(|line| {
            let line = line.trim_end_matches('\r');
            line.rsplit('\r').next().unwrap_or(line)
        })
        .collect::<Vec<_>>()
        .join("\n")
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
        // EXIT marker missing (timeout, or the shell ended): all after START.
        (Some(s), None) => {
            let after_start = raw[s..].find('\n').map_or(raw.len(), |n| s + n + 1);
            &raw[after_start..]
        }
        _ => raw,
    };
    // PTYs emit CRLF; normalize to LF for clean agent-facing text.
    collapse_cr(&strip_ansi(body).replace("\r\n", "\n"))
        .trim_matches(['\r', '\n'])
        .to_owned()
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
        .send(terminal_data(terminal_id, &framed_command(command, &platform)))
        .await?;

    let mut raw = String::new();
    let mut shell_closed = false;
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let Some(msg) = session.next_message_until(deadline).await? else {
            break; // deadline reached without the exit marker
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
                // The shell itself ended before the EXIT marker. Its exit code
                // here is not reliably the command's: the peer reports 0 when it
                // reads the status before the process has exited.
                log::debug!("terminal {} closed, exit {}", c.terminal_id, c.exit_code);
                shell_closed = true;
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
        // Show what the command printed last, so the caller can see why: a
        // prompt waiting for input, a pager, a parse error, or output still coming.
        let seen = clean_output(&raw);
        let tail = seen
            .char_indices()
            .rev()
            .nth(599)
            .map_or(seen.as_str(), |(i, _)| &seen[i..]);
        if shell_closed {
            bail!(
                "the shell on {id} exited before the command finished (did the command run `exit`?), so its exit code is unknown; last output:\n{tail}"
            );
        }
        bail!(
            "command did not finish within 60s (waiting for input, or still running); last output:\n{tail}"
        );
    };
    Ok(TerminalRun {
        output: clean_output(&raw),
        exit_code,
        platform,
    })
}
