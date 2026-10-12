//! FPRemote agent: a headless RustDesk client that lets an AI agent serve
//! clinic computers over an MCP server. See docs/agent.md in the fp-remote
//! repo for the design. Built only with the `fp-agent` feature.

mod config;
mod files;
mod mcp;
mod pro;
mod session;
mod terminal;

use std::path::Path;

use hbb_common::{anyhow::anyhow, bail, ResultType};

use config::AgentConfig;
use pro::ProSession;

const USAGE: &str = "\
fpremote-agent — FPRemote client for AI agents

USAGE:
    fpremote-agent <COMMAND>

COMMANDS:
    login                               Log in to the Pro server and report the session
    devices                             List the clinic computers this account can reach
    terminal <id> -- <cmd>              Run a shell command on a peer and print its output
    ls <id> <remote-dir>                List a directory on a peer
    download <id> <remote-file> <local> Copy a file from a peer to this machine
    mcp                                 Run the MCP server over stdio (for AI agents)
    help                                Show this help

OPTIONS (peer commands):
    --password <pw>    Connect password for the peer (else taken from the shared address book)
";

/// Entry point called by the thin binary. Runs one command to completion.
pub fn main() {
    // Before anything touches config or logs, so both live under the agent's
    // own name and never mix with a RustDesk install on the same machine.
    *hbb_common::config::APP_NAME.write().unwrap() = config::APP_NAME.to_owned();
    hbb_common::init_log(false, "fpremote-agent");
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("help");

    let runtime = match hbb_common::tokio::runtime::Runtime::new() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("cannot start runtime: {}", e);
            std::process::exit(1);
        }
    };
    let result = runtime.block_on(run(command));
    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}

async fn run(command: &str) -> ResultType<()> {
    match command {
        "login" => {
            let (cfg, session) = connect().await?;
            println!(
                "logged in as {} on {}; access token acquired ({} chars)",
                cfg.username,
                cfg.api,
                session.token.len()
            );
            session.logout().await?;
            Ok(())
        }
        "devices" => {
            let (_cfg, session) = connect().await?;
            let devices = session.devices().await?;
            println!("{} device(s):", devices.len());
            for d in &devices {
                let name = if d.alias.is_empty() { &d.id } else { &d.alias };
                println!(
                    "  {}\t{}\t{}\t{}\t{}",
                    d.id, name, d.device_group_name, d.platform, d.hostname
                );
            }
            session.logout().await?;
            Ok(())
        }
        "terminal" => run_terminal().await,
        "ls" => run_ls().await,
        "download" => run_download().await,
        "mcp" => mcp::serve().await,
        "help" | "--help" | "-h" => {
            print!("{}", USAGE);
            Ok(())
        }
        other => {
            eprintln!("unknown command: {}\n\n{}", other, USAGE);
            std::process::exit(2);
        }
    }
}

async fn connect() -> ResultType<(AgentConfig, ProSession)> {
    let cfg = AgentConfig::load()?;
    cfg.bootstrap();
    let session = ProSession::login(&cfg).await?;
    Ok((cfg, session))
}

/// Peer-command arguments: the peer id, an optional `--password`, and the
/// remaining positional arguments (everything after `--` is kept verbatim).
struct PeerArgs {
    id: String,
    password: String,
    rest: Vec<String>,
}

fn peer_args(usage: &str) -> ResultType<PeerArgs> {
    let args: Vec<String> = std::env::args().skip(2).collect();
    let id = args
        .first()
        .filter(|s| !s.starts_with('-'))
        .cloned()
        .ok_or_else(|| anyhow!("usage: {usage}"))?;
    let mut password = String::new();
    let mut rest = Vec::new();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--password" => {
                password = args.get(i + 1).cloned().unwrap_or_default();
                i += 2;
            }
            "--" => {
                rest.extend_from_slice(&args[i + 1..]);
                break;
            }
            other => {
                rest.push(other.to_owned());
                i += 1;
            }
        }
    }
    Ok(PeerArgs { id, password, rest })
}

/// Use the given password, else the peer's stored one in a shared address book.
async fn resolve_password(session: &ProSession, id: &str, password: String) -> String {
    if !password.is_empty() {
        return password;
    }
    session
        .devices()
        .await
        .ok()
        .and_then(|devices| {
            devices
                .into_iter()
                .find(|d| d.id == id && !d.password.is_empty())
                .map(|d| d.password)
        })
        .unwrap_or_default()
}

async fn run_terminal() -> ResultType<()> {
    let a = peer_args("fpremote-agent terminal <id> [--password <pw>] -- <command>")?;
    if a.rest.is_empty() {
        bail!("no command given; use: terminal <id> --password <pw> -- <command>");
    }
    let command = a.rest.join(" ");
    let (cfg, session) = connect().await?;
    let password = resolve_password(&session, &a.id, a.password).await;
    let run = terminal::run_command(&cfg.key, &session.token, &a.id, &password, &command).await;
    session.logout().await.ok();
    let run = run?;
    print!("{}", run.output);
    if !run.output.ends_with('\n') {
        println!();
    }
    eprintln!("[{} exit {}]", run.platform, run.exit_code);
    std::process::exit(if run.exit_code == 0 { 0 } else { 1 });
}

async fn run_ls() -> ResultType<()> {
    let a = peer_args("fpremote-agent ls <id> <remote-dir> [--password <pw>]")?;
    let path = a.rest.first().cloned().ok_or_else(|| anyhow!("missing <remote-dir>"))?;
    let (cfg, session) = connect().await?;
    let password = resolve_password(&session, &a.id, a.password).await;
    let entries = files::list(&cfg.key, &session.token, &a.id, &password, &path, false).await;
    session.logout().await.ok();
    for e in entries? {
        println!(
            "{}\t{}\t{}\t{}",
            if e.is_dir { "d" } else { "-" },
            e.size,
            e.modified,
            e.name
        );
    }
    Ok(())
}

async fn run_download() -> ResultType<()> {
    let a = peer_args("fpremote-agent download <id> <remote-file> <local> [--password <pw>]")?;
    let (remote, local) = match a.rest.as_slice() {
        [r, l, ..] => (r.clone(), l.clone()),
        _ => bail!("need <remote-file> and <local>"),
    };
    let (cfg, session) = connect().await?;
    let password = resolve_password(&session, &a.id, a.password).await;
    let n = files::download(
        &cfg.key,
        &session.token,
        &a.id,
        &password,
        &remote,
        Path::new(&local),
    )
    .await;
    session.logout().await.ok();
    println!("downloaded {} bytes to {}", n?, local);
    Ok(())
}
