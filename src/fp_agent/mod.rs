//! FPRemote agent: a headless RustDesk client that lets an AI agent serve
//! clinic computers over an MCP server. See docs/agent.md in the fp-remote
//! repo for the design. Built only with the `fp-agent` feature.

mod config;
mod pro;
mod session;
mod terminal;

use hbb_common::ResultType;

use config::AgentConfig;
use pro::ProSession;

const USAGE: &str = "\
fpremote-agent — FPRemote client for AI agents

USAGE:
    fpremote-agent <COMMAND>

COMMANDS:
    login                       Log in to the Pro server and report the session
    devices                     List the clinic computers this account can reach
    terminal <id> -- <cmd>      Run a shell command on a peer and print its output
    help                        Show this help

OPTIONS for terminal:
    --password <pw>             Connect password for the peer (else taken from the shared address book)
";

/// Entry point called by the thin binary. Runs one command to completion.
pub fn main() {
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
                    d.id,
                    name,
                    d.device_group_name,
                    d.platform,
                    d.hostname
                );
            }
            session.logout().await?;
            Ok(())
        }
        "terminal" => run_terminal().await,
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

async fn run_terminal() -> ResultType<()> {
    let args: Vec<String> = std::env::args().skip(2).collect();
    let id = args
        .first()
        .filter(|s| !s.starts_with('-'))
        .cloned()
        .ok_or_else(|| hbb_common::anyhow::anyhow!("usage: fpremote-agent terminal <id> [--password <pw>] -- <command>"))?;
    let mut password = String::new();
    let mut command: Vec<String> = Vec::new();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--password" => {
                password = args.get(i + 1).cloned().unwrap_or_default();
                i += 2;
            }
            "--" => {
                command = args[i + 1..].to_vec();
                break;
            }
            other => {
                command.push(other.to_owned());
                i += 1;
            }
        }
    }
    if command.is_empty() {
        hbb_common::bail!("no command given; use: terminal <id> --password <pw> -- <command>");
    }
    let command = command.join(" ");

    let (cfg, session) = connect().await?;
    // Fall back to the peer's stored password in the shared address book.
    if password.is_empty() {
        if let Ok(devices) = session.devices().await {
            if let Some(p) = devices
                .iter()
                .find(|d| d.id == id && !d.password.is_empty())
            {
                password = p.password.clone();
            }
        }
    }

    let run = terminal::run_command(&cfg.key, &session.token, &id, &password, &command).await?;
    session.logout().await.ok();
    print!("{}", run.output);
    if !run.output.ends_with('\n') {
        println!();
    }
    eprintln!("[{} exit {}]", run.platform, run.exit_code);
    std::process::exit(if run.exit_code == 0 { 0 } else { 1 });
}
