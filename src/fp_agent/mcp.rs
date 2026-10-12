//! MCP server over stdio: newline-delimited JSON-RPC 2.0, one message per line.
//! stdout carries only MCP messages; logs go to the log file and stderr.
//! Each peer-affecting tool call is recorded in the audit log.

use std::{collections::HashMap, path::Path};

use hbb_common::{
    log,
    tokio::{
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        sync::mpsc,
    },
    ResultType,
};
use serde_json::{json, Value};

use crate::client::Data;

use super::{config::AgentConfig, files, pro::ProSession, terminal, tunnel};

/// Live tunnels opened via `open_tunnel`, keyed by local port; the sender stops
/// the tunnel when `Data::Close` is sent on it.
type Tunnels = HashMap<i32, mpsc::UnboundedSender<Data>>;

const SERVER_NAME: &str = "fpremote-agent";
const PROTOCOL_VERSION: &str = "2024-11-05";

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

    while let Some(line) = reader.next_line().await? {
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
                let resp = handle_call(&cfg, &mut session, &mut tunnels, req.get("params")).await;
                let result = match resp {
                    Ok(text) => tool_text(&text, false),
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
    session.logout().await.ok();
    Ok(())
}

async fn handle_call(
    cfg: &AgentConfig,
    session: &mut ProSession,
    tunnels: &mut Tunnels,
    params: Option<&Value>,
) -> ResultType<String> {
    let params = params.cloned().unwrap_or(json!({}));
    let name = params.get("name").and_then(|n| n.as_str()).unwrap_or_default();
    let args = params.get("arguments").cloned().unwrap_or(json!({}));

    let str_arg = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or_default().to_owned();
    let id = str_arg("device_id");
    AgentConfig::append_audit(&json!({
        "ts": hbb_common::get_time(),
        "tool": name,
        "device_id": id,
        "args": redact_args(&args),
    }).to_string());

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
            let run =
                terminal::run_command(&cfg.key, &session.token, &id, &password, &command).await?;
            Ok(format!("[{} exit {}]\n{}", run.platform, run.exit_code, run.output))
        }
        "list_files" => {
            let path = str_arg("path");
            if id.is_empty() || path.is_empty() {
                return Ok("device_id and path are required".to_owned());
            }
            let password = password_for(session, &id, str_arg("password")).await;
            let entries =
                files::list(&cfg.key, &session.token, &id, &password, &path, false).await?;
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
            let n = files::download(
                &cfg.key,
                &session.token,
                &id,
                &password,
                &remote,
                Path::new(&local),
            )
            .await?;
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
        other => Ok(format!("unknown tool: {other}")),
    }
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
            "description": "Run a shell command on a peer and return its stdout/stderr and exit code.",
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
