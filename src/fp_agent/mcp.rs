//! MCP server over stdio: newline-delimited JSON-RPC 2.0, one message per line.
//! stdout carries only MCP messages; logs go to the log file and stderr.
//! Each peer-affecting tool call is recorded in the audit log.

use std::{
    collections::HashMap,
    path::Path,
    time::{Duration, Instant},
};

use hbb_common::{
    bail, log,
    rendezvous_proto::ConnType,
    tokio::{
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        sync::mpsc,
        time::{interval, MissedTickBehavior},
    },
    ResultType,
};
use serde_json::{json, Value};

use crate::client::Data;

use super::{
    config::AgentConfig,
    files,
    pro::ProSession,
    screen,
    session::{connect_and_login, require_password, Session},
    terminal, tunnel,
};

/// Live tunnels opened via `open_tunnel`, keyed by local port; the sender stops
/// the tunnel when `Data::Close` is sent on it.
type Tunnels = HashMap<i32, mpsc::UnboundedSender<Data>>;

const SERVER_NAME: &str = "fpremote-agent";
const PROTOCOL_VERSION: &str = "2024-11-05";

/// How long a connection to a computer stays open after the last call on it.
/// Calls in that time reuse it, so a piece of work shows the computer's FPRemote
/// panel once instead of once per call.
const IDLE_CLOSE: Duration = Duration::from_secs(120);
/// How often idle connections answer the peer's keepalives (the peer closes a
/// connection it hears nothing from for 30 s) and are checked against IDLE_CLOSE.
const KEEPALIVE_EVERY: Duration = Duration::from_secs(5);

/// Open terminal and file-transfer connections, by peer id and connection type.
/// Screen tools still connect per call: while a remote-control connection is
/// open the peer captures and sends its screen.
#[derive(Default)]
struct Pool {
    conns: HashMap<(String, i32), (Session, Instant)>,
}

impl Pool {
    /// The open connection to `id` of this type if it is still alive, else a new one.
    async fn take(
        &mut self,
        cfg: &AgentConfig,
        token: &str,
        id: &str,
        password: &str,
        conn_type: ConnType,
    ) -> ResultType<Session> {
        // Taken out before the password check, so a computer the account can no
        // longer reach loses its open connection as well.
        let open = self.conns.remove(&(id.to_owned(), conn_type as i32));
        require_password(id, password)?;
        if let Some((mut session, _)) = open {
            match session.drain().await {
                Ok(()) => return Ok(session),
                Err(e) => log::info!("connection to {id} is gone ({e}); reconnecting"),
            }
        }
        connect_and_login(&cfg.key, token, id, password, conn_type).await
    }

    /// Keep a connection after a call, for the next one.
    fn put_back(&mut self, id: &str, conn_type: ConnType, session: Session) {
        self.conns
            .insert((id.to_owned(), conn_type as i32), (session, Instant::now()));
    }

    /// Answer the keepalives of idle connections; close the ones unused for
    /// IDLE_CLOSE and the ones the peer has closed.
    async fn tick(&mut self) {
        let keys: Vec<(String, i32)> = self.conns.keys().cloned().collect();
        for key in keys {
            let Some((mut session, last_used)) = self.conns.remove(&key) else {
                continue;
            };
            if last_used.elapsed() >= IDLE_CLOSE {
                log::info!("closing the idle connection to {}", key.0);
                continue;
            }
            if session.drain().await.is_ok() {
                self.conns.insert(key, (session, last_used));
            }
        }
    }

    /// Close the open connections to `id`, or all of them when `id` is empty.
    fn close(&mut self, id: &str) -> usize {
        let before = self.conns.len();
        self.conns.retain(|(peer, _), _| !id.is_empty() && peer != id);
        before - self.conns.len()
    }
}

/// Run the MCP server loop until stdin closes.
pub async fn serve() -> ResultType<()> {
    let cfg = AgentConfig::load()?;
    cfg.bootstrap();
    // One Pro login for the server's lifetime; re-login lazily if a call fails auth.
    let mut session = ProSession::login(&cfg).await?;
    log::info!("fpremote-agent MCP server ready as {}", cfg.username);

    let stdin = hbb_common::tokio::io::stdin();
    let mut reader = BufReader::new(stdin).lines();
    let mut stdout = hbb_common::tokio::io::stdout();
    let mut tunnels: Tunnels = HashMap::new();
    let mut pool = Pool::default();
    let mut keepalive = interval(KEEPALIVE_EVERY);
    keepalive.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        let line = hbb_common::tokio::select! {
            line = reader.next_line() => match line? {
                Some(line) => line,
                None => break,
            },
            _ = keepalive.tick() => {
                pool.tick().await;
                continue;
            }
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let req: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => {
                write_msg(&mut stdout, &error_resp(Value::Null, -32700, &format!("parse error: {e}")))
                    .await?;
                continue;
            }
        };
        let id = req.get("id").cloned().unwrap_or(Value::Null);
        let method = req.get("method").and_then(|m| m.as_str()).unwrap_or_default();
        let is_notification = req.get("id").is_none();

        match method {
            "initialize" => {
                write_msg(&mut stdout, &ok_resp(id, initialize_result())).await?;
            }
            "notifications/initialized" | "notifications/cancelled" => { /* no reply */ }
            "ping" => write_msg(&mut stdout, &ok_resp(id, json!({}))).await?,
            "tools/list" => write_msg(&mut stdout, &ok_resp(id, json!({ "tools": tools() }))).await?,
            "tools/call" => {
                let resp =
                    handle_call(&cfg, &mut session, &mut tunnels, &mut pool, req.get("params")).await;
                let result = match resp {
                    Ok(result) => result,
                    Err(e) => tool_text(&format!("error: {e}"), true),
                };
                write_msg(&mut stdout, &ok_resp(id, result)).await?;
            }
            _ if is_notification => { /* ignore unknown notifications */ }
            other => {
                write_msg(
                    &mut stdout,
                    &error_resp(id, -32601, &format!("method not found: {other}")),
                )
                .await?;
            }
        }
    }
    for (_, tx) in tunnels.drain() {
        let _ = tx.send(Data::Close);
    }
    pool.close("");
    session.logout().await.ok();
    Ok(())
}

async fn handle_call(
    cfg: &AgentConfig,
    session: &mut ProSession,
    tunnels: &mut Tunnels,
    pool: &mut Pool,
    params: Option<&Value>,
) -> ResultType<Value> {
    let params = params.cloned().unwrap_or(json!({}));
    let name = params.get("name").and_then(|n| n.as_str()).unwrap_or_default();
    let args = params.get("arguments").cloned().unwrap_or(json!({}));
    AgentConfig::append_audit(&json!({
        "ts": hbb_common::get_time(),
        "tool": name,
        "device_id": args.get("device_id").and_then(|v| v.as_str()).unwrap_or_default(),
        "args": redact_args(&args),
    }).to_string());

    if name == "screenshot" {
        return screenshot_tool(cfg, session, &args).await;
    }
    Ok(tool_text(&text_tool(cfg, session, tunnels, pool, name, &args).await?, false))
}

/// Tools whose result is plain text.
async fn text_tool(
    cfg: &AgentConfig,
    session: &mut ProSession,
    tunnels: &mut Tunnels,
    pool: &mut Pool,
    name: &str,
    args: &Value,
) -> ResultType<String> {
    let str_arg = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or_default().to_owned();
    let id = str_arg("device_id");

    match name {
        "list_devices" => {
            let devices = session.devices().await?;
            let rows: Vec<Value> = devices
                .iter()
                .map(|d| {
                    json!({
                        "id": d.id,
                        "alias": d.alias,
                        "group": d.device_group_name,
                        "platform": d.platform,
                        "hostname": d.hostname,
                        "has_password": !d.password.is_empty(),
                    })
                })
                .collect();
            Ok(serde_json::to_string_pretty(&rows)?)
        }
        "run_terminal" => {
            let command = str_arg("command");
            if id.is_empty() || command.is_empty() {
                return Ok("device_id and command are required".to_owned());
            }
            let password = password_for(session, &id, str_arg("password")).await;
            let mut conn = pool.take(cfg, &session.token, &id, &password, ConnType::TERMINAL).await?;
            let run = terminal::run_on(&mut conn, &id, &command).await;
            pool.put_back(&id, ConnType::TERMINAL, conn);
            let run = run?;
            Ok(format!("[{} exit {}]\n{}", run.platform, run.exit_code, run.output))
        }
        "list_files" => {
            let path = str_arg("path");
            if id.is_empty() || path.is_empty() {
                return Ok("device_id and path are required".to_owned());
            }
            let password = password_for(session, &id, str_arg("password")).await;
            let mut conn = pool.take(cfg, &session.token, &id, &password, ConnType::FILE_TRANSFER).await?;
            let entries = files::list_on(&mut conn, &id, &path, false).await;
            pool.put_back(&id, ConnType::FILE_TRANSFER, conn);
            let entries = entries?;
            let rows: Vec<Value> = entries
                .iter()
                .map(|e| json!({ "name": e.name, "is_dir": e.is_dir, "size": e.size, "modified": e.modified }))
                .collect();
            Ok(serde_json::to_string_pretty(&rows)?)
        }
        "download_file" => {
            let remote = str_arg("remote_path");
            let local = str_arg("local_path");
            if id.is_empty() || remote.is_empty() || local.is_empty() {
                return Ok("device_id, remote_path and local_path are required".to_owned());
            }
            let password = password_for(session, &id, str_arg("password")).await;
            let mut conn = pool.take(cfg, &session.token, &id, &password, ConnType::FILE_TRANSFER).await?;
            let n = files::download_on(&mut conn, &id, &remote, Path::new(&local)).await;
            pool.put_back(&id, ConnType::FILE_TRANSFER, conn);
            let n = n?;
            Ok(format!("downloaded {n} bytes to {local}"))
        }
        "open_tunnel" => {
            let num = |k: &str| args.get(k).and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let local_port = num("local_port");
            let remote_host = str_arg("remote_host");
            let remote_port = num("remote_port");
            if id.is_empty() || remote_host.is_empty() {
                return Ok("device_id and remote_host are required".to_owned());
            }
            if !(1..=65535).contains(&local_port) || !(1..=65535).contains(&remote_port) {
                return Ok("local_port and remote_port must be 1-65535".to_owned());
            }
            if tunnels.contains_key(&local_port) {
                return Ok(format!("a tunnel already uses local port {local_port}"));
            }
            let password = password_for(session, &id, str_arg("password")).await;
            // Check before spawning: the tool must not report an open tunnel that
            // cannot log in.
            require_password(&id, &password)?;
            let (tx, rx) = mpsc::unbounded_channel::<Data>();
            let (key, token, id2, host) =
                (cfg.key.clone(), session.token.clone(), id.clone(), remote_host.clone());
            hbb_common::tokio::spawn(async move {
                if let Err(e) = tunnel::run_with_receiver(
                    &key, &token, &id2, &password, local_port, &host, remote_port, rx,
                )
                .await
                {
                    log::warn!("tunnel on {local_port} ended: {e}");
                }
            });
            tunnels.insert(local_port, tx);
            Ok(format!(
                "tunnel open: localhost:{local_port} -> {remote_host}:{remote_port} via {id}"
            ))
        }
        "disconnect" => {
            let n = pool.close(&id);
            Ok(if id.is_empty() {
                format!("closed {n} open connection(s)")
            } else {
                format!("closed {n} open connection(s) to {id}")
            })
        }
        "list_tunnels" => {
            let mut ports: Vec<i32> = tunnels.keys().copied().collect();
            ports.sort_unstable();
            Ok(serde_json::to_string_pretty(&ports)?)
        }
        "close_tunnel" => {
            let local_port = args.get("local_port").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            match tunnels.remove(&local_port) {
                Some(tx) => {
                    let _ = tx.send(Data::Close);
                    Ok(format!("tunnel on local port {local_port} closed"))
                }
                None => Ok(format!("no tunnel on local port {local_port}")),
            }
        }
        "upload_file" => {
            let (local, remote) = (str_arg("local_path"), str_arg("remote_path"));
            if id.is_empty() || local.is_empty() || remote.is_empty() {
                bail!("device_id, local_path and remote_path are required");
            }
            let password = password_for(session, &id, str_arg("password")).await;
            let mut conn = pool.take(cfg, &session.token, &id, &password, ConnType::FILE_TRANSFER).await?;
            let n = files::upload_on(&mut conn, &id, Path::new(&local), &remote).await;
            pool.put_back(&id, ConnType::FILE_TRANSFER, conn);
            let n = n?;
            Ok(format!("uploaded {n} bytes to {remote} on {id}"))
        }
        "make_directory" => {
            let path = str_arg("path");
            if id.is_empty() || path.is_empty() {
                bail!("device_id and path are required");
            }
            let password = password_for(session, &id, str_arg("password")).await;
            let mut conn = pool.take(cfg, &session.token, &id, &password, ConnType::FILE_TRANSFER).await?;
            let done = files::mkdir_on(&mut conn, &id, &path).await;
            pool.put_back(&id, ConnType::FILE_TRANSFER, conn);
            done?;
            Ok(format!("created {path} on {id}"))
        }
        "remove_path" => {
            let path = str_arg("path");
            if id.is_empty() || path.is_empty() {
                bail!("device_id and path are required");
            }
            let is_dir = args.get("is_directory").and_then(|v| v.as_bool()).unwrap_or(false);
            let password = password_for(session, &id, str_arg("password")).await;
            let mut conn = pool.take(cfg, &session.token, &id, &password, ConnType::FILE_TRANSFER).await?;
            let done = files::remove_on(&mut conn, &id, &path, is_dir).await;
            pool.put_back(&id, ConnType::FILE_TRANSFER, conn);
            done?;
            Ok(format!("removed {path} on {id}"))
        }
        "mouse" => {
            require_reason(args)?;
            if id.is_empty() {
                bail!("device_id is required");
            }
            let action = screen::MouseAction::parse(&str_arg("action"), int_arg(args, "dy"))?;
            let (x, y, display) = (int_arg(args, "x"), int_arg(args, "y"), int_arg(args, "display"));
            let password = password_for(session, &id, str_arg("password")).await;
            screen::mouse(&cfg.key, &session.token, &id, &password, display, action, x, y).await?;
            Ok(format!("mouse {action:?} at {x},{y} on display {display} of {id}"))
        }
        "keyboard" => {
            require_reason(args)?;
            if id.is_empty() {
                bail!("device_id is required");
            }
            let (text, key) = (str_arg("text"), str_arg("key"));
            let action = match (text.is_empty(), key.is_empty()) {
                (false, true) => screen::KeyboardAction::Type(&text),
                (true, false) => screen::KeyboardAction::Press(&key),
                _ => bail!("give exactly one of text or key"),
            };
            let focus = match (
                args.get("click_x").and_then(|v| v.as_i64()),
                args.get("click_y").and_then(|v| v.as_i64()),
            ) {
                (Some(x), Some(y)) => Some((int_arg(args, "display"), x as i32, y as i32)),
                _ => None,
            };
            let password = password_for(session, &id, str_arg("password")).await;
            screen::keyboard(&cfg.key, &session.token, &id, &password, action, focus).await?;
            let where_ = focus.map_or(String::new(), |(_, x, y)| format!(" (clicked {x},{y} first)"));
            Ok(format!("keyboard input sent to {id}{where_}"))
        }
        other => Ok(format!("unknown tool: {other}")),
    }
}

fn int_arg(args: &Value, k: &str) -> i32 {
    args.get(k).and_then(|v| v.as_i64()).unwrap_or(0) as i32
}

/// Screen tools see and touch whatever is on the clinic screen, patient data
/// included, so every call must say why the terminal and files are not enough.
/// The reason is in the arguments and so in the audit log.
fn require_reason(args: &Value) -> ResultType<()> {
    let reason = args.get("reason").and_then(|v| v.as_str()).unwrap_or_default().trim();
    if reason.chars().count() < 10 {
        bail!("reason is required: say why the terminal or files cannot do this (it is written to the audit log)");
    }
    Ok(())
}

/// One screenshot as an MCP image, plus its size so mouse coordinates line up.
async fn screenshot_tool(cfg: &AgentConfig, session: &mut ProSession, args: &Value) -> ResultType<Value> {
    require_reason(args)?;
    let str_arg = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or_default().to_owned();
    let id = str_arg("device_id");
    if id.is_empty() {
        bail!("device_id is required");
    }
    let display = int_arg(args, "display");
    let password = password_for(session, &id, str_arg("password")).await;
    let shot = screen::screenshot(&cfg.key, &session.token, &id, &password, display).await?;
    let data = hbb_common::sodiumoxide::base64::encode(
        &shot.png,
        hbb_common::sodiumoxide::base64::Variant::Original,
    );
    Ok(json!({
        "content": [
            { "type": "image", "data": data, "mimeType": "image/png" },
            { "type": "text", "text": format!(
                "display {display} of {id}: {}x{} pixels; mouse x/y are pixels in this image",
                shot.width, shot.height
            ) }
        ],
        "isError": false
    }))
}

/// Explicit password, else the peer's stored one in a shared address book.
async fn password_for(session: &ProSession, id: &str, given: String) -> String {
    if !given.is_empty() {
        return given;
    }
    session
        .devices()
        .await
        .ok()
        .and_then(|d| d.into_iter().find(|p| p.id == id && !p.password.is_empty()).map(|p| p.password))
        .unwrap_or_default()
}

fn redact_args(args: &Value) -> Value {
    let mut a = args.clone();
    if let Some(obj) = a.as_object_mut() {
        if obj.contains_key("password") {
            obj.insert("password".to_owned(), json!("***"));
        }
    }
    a
}

fn initialize_result() -> Value {
    json!({
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": { "tools": {} },
        "serverInfo": { "name": SERVER_NAME, "version": env!("CARGO_PKG_VERSION") }
    })
}

fn tools() -> Value {
    json!([
        {
            "name": "list_devices",
            "description": "List the clinic computers (FPRemote peers) this agent can reach through shared address books.",
            "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
        },
        {
            "name": "run_terminal",
            "description": "Run a shell command on a peer, in a new shell each time, and return its stdout/stderr and exit code. Terminal and file calls keep their connection to the peer open for 2 minutes after the last call; call disconnect when the work on that computer is done.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string", "description": "FPRemote peer id" },
                    "command": { "type": "string", "description": "Shell command to run" },
                    "password": { "type": "string", "description": "Connect password; omit to use the shared address book" }
                },
                "required": ["device_id", "command"]
            }
        },
        {
            "name": "list_files",
            "description": "List a directory on a peer (served by the peer's connection manager; a user must be logged in on the peer).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "path": { "type": "string", "description": "Absolute directory path on the peer" },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "path"]
            }
        },
        {
            "name": "download_file",
            "description": "Copy one file from a peer to this machine.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "remote_path": { "type": "string" },
                    "local_path": { "type": "string" },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "remote_path", "local_path"]
            }
        },
        {
            "name": "upload_file",
            "description": "Copy one file from this machine to a peer, replacing the file at remote_path (served by the peer's connection manager; a user must be logged in on the peer).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "local_path": { "type": "string" },
                    "remote_path": { "type": "string", "description": "Full destination file path on the peer" },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "local_path", "remote_path"]
            }
        },
        {
            "name": "make_directory",
            "description": "Create a directory on a peer (served by the peer's connection manager).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "path": { "type": "string" },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "path"]
            }
        },
        {
            "name": "remove_path",
            "description": "Remove a file, or an empty directory (is_directory: true), on a peer. A directory with files in it is refused; use run_terminal for that.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "path": { "type": "string" },
                    "is_directory": { "type": "boolean" },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "path"]
            }
        },
        {
            "name": "open_tunnel",
            "description": "Forward localhost:<local_port> on this machine to <remote_host>:<remote_port> as seen from the peer (e.g. a printer, a fiscal device or a service on the clinic network). Stays open until close_tunnel or the server exits.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "local_port": { "type": "integer", "minimum": 1, "maximum": 65535 },
                    "remote_host": { "type": "string", "description": "Host as seen from the peer, e.g. 127.0.0.1 or 192.168.1.50" },
                    "remote_port": { "type": "integer", "minimum": 1, "maximum": 65535 },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "local_port", "remote_host", "remote_port"]
            }
        },
        {
            "name": "disconnect",
            "description": "Close the open terminal and file connections to a peer (to every peer when device_id is omitted). While they are open the computer shows the FPRemote panel; they also close by themselves 2 minutes after the last call. Tunnels close with close_tunnel.",
            "inputSchema": {
                "type": "object",
                "properties": { "device_id": { "type": "string" } }
            }
        },
        {
            "name": "list_tunnels",
            "description": "List the local ports of tunnels opened in this session.",
            "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
        },
        {
            "name": "close_tunnel",
            "description": "Close the tunnel listening on local_port.",
            "inputSchema": {
                "type": "object",
                "properties": { "local_port": { "type": "integer" } },
                "required": ["local_port"]
            }
        },
        {
            "name": "screenshot",
            "description": "LAST RESORT. Take one screenshot of a peer's display and return it as an image. Clinic screens show patient data and the image goes to the model provider: use run_terminal, list_files and download_file first, and look at the screen only when the task needs it (a program with no command line, an error dialog). Every call is logged with its reason.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "reason": { "type": "string", "description": "Why the terminal or files cannot do this (written to the audit log)" },
                    "display": { "type": "integer", "minimum": 0, "description": "0 = primary display" },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "reason"]
            }
        },
        {
            "name": "mouse",
            "description": "LAST RESORT. Move, click, double-click, right-click or scroll on a peer's display. x/y are pixels in that display's screenshot: take a screenshot first to find the target and another one after to check the result. Logged with its reason.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "reason": { "type": "string", "description": "Why the terminal or files cannot do this (written to the audit log)" },
                    "action": { "type": "string", "enum": ["move", "click", "double_click", "right_click", "scroll"] },
                    "x": { "type": "integer" },
                    "y": { "type": "integer" },
                    "dy": { "type": "integer", "description": "Scroll only: wheel notches, positive = up" },
                    "display": { "type": "integer", "minimum": 0 },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "reason", "action", "x", "y"]
            }
        },
        {
            "name": "keyboard",
            "description": "LAST RESORT. Type text, or press one key or combination (enter, esc, tab, f5, ctrl+c, alt+f4, ctrl+alt+del), on a peer. Input goes to the window that has focus there; click_x/click_y (pixels in that display's screenshot) click a window first so the input goes to it. On Windows they are required (except for ctrl+alt+del): the FPRemote session window takes the focus when the agent connects. Give exactly one of text or key. Logged with its reason.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "device_id": { "type": "string" },
                    "reason": { "type": "string", "description": "Why the terminal or files cannot do this (written to the audit log)" },
                    "text": { "type": "string", "description": "Text to type as-is" },
                    "key": { "type": "string", "description": "Key or combination, e.g. enter, ctrl+c" },
                    "click_x": { "type": "integer", "description": "Click this x (with click_y) to focus the target window before the input" },
                    "click_y": { "type": "integer", "description": "Click this y (with click_x) to focus the target window before the input" },
                    "display": { "type": "integer", "minimum": 0, "description": "Display for click_x/click_y (0 = primary)" },
                    "password": { "type": "string" }
                },
                "required": ["device_id", "reason"]
            }
        }
    ])
}

fn tool_text(text: &str, is_error: bool) -> Value {
    json!({ "content": [ { "type": "text", "text": text } ], "isError": is_error })
}

fn ok_resp(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn error_resp(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

async fn write_msg<W: AsyncWriteExt + Unpin>(out: &mut W, msg: &Value) -> ResultType<()> {
    let mut line = serde_json::to_string(msg)?;
    line.push('\n');
    out.write_all(line.as_bytes()).await?;
    out.flush().await?;
    Ok(())
}
