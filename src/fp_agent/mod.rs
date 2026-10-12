//! FPRemote agent: a headless RustDesk client that lets an AI agent serve
//! clinic computers over an MCP server. See docs/agent.md in the fp-remote
//! repo for the design. Built only with the `fp-agent` feature.

mod config;
mod pro;

use hbb_common::ResultType;

use config::AgentConfig;
use pro::ProSession;

const USAGE: &str = "\
fpremote-agent — FPRemote client for AI agents

USAGE:
    fpremote-agent <COMMAND>

COMMANDS:
    login      Log in to the Pro server and report the session
    devices    List the clinic computers this account can reach
    help       Show this help
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
