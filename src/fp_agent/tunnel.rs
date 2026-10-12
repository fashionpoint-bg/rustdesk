use std::sync::{Arc, RwLock};

use hbb_common::{
    config::LocalConfig,
    log,
    rendezvous_proto::ConnType,
    tokio::sync::mpsc,
    ResultType,
};

use crate::client::{Data, LoginConfigHandler};

use super::session::AgentInterface;

/// Open a local TCP listener on `local_port` that forwards every connection to
/// `remote_host:remote_port` as seen from the peer, over the P2P tunnel. Runs
/// until the process is stopped. The channel sender is held so the listener's
/// `select!` never busy-loops on a closed receiver; sending `Data::Close` on it
/// would stop the listener.
pub async fn run(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    local_port: i32,
    remote_host: &str,
    remote_port: i32,
) -> ResultType<()> {
    // Hold the sender for the lifetime of the listener so its receiver stays open.
    let (_keep_sender, receiver) = mpsc::unbounded_channel::<Data>();
    run_with_receiver(
        key, token, id, password, local_port, remote_host, remote_port, receiver,
    )
    .await
}

/// Same as [`run`], but the caller supplies the control receiver so it can stop
/// the tunnel later by sending [`Data::Close`] on the paired sender. Used by the
/// MCP server's `open_tunnel` / `close_tunnel` tools.
pub async fn run_with_receiver(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    local_port: i32,
    remote_host: &str,
    remote_port: i32,
    receiver: mpsc::UnboundedReceiver<Data>,
) -> ResultType<()> {
    if !token.is_empty() {
        LocalConfig::set_option("access_token".to_owned(), token.to_owned());
    }

    let lc = Arc::new(RwLock::new(LoginConfigHandler::default()));
    lc.write().unwrap().initialize(
        id.to_owned(),
        ConnType::PORT_FORWARD,
        None,
        false,
        None,
        None,
        None,
    );
    lc.write().unwrap().port_forward_mux = crate::port_forward::mux_enabled();

    let interface = AgentInterface::new(lc.clone());

    log::info!(
        "tunnel localhost:{local_port} -> {remote_host}:{remote_port} via {id}"
    );
    eprintln!(
        "tunnel: localhost:{local_port} -> {remote_host}:{remote_port} via {id} (stop with Ctrl-C)"
    );

    crate::port_forward::listen(
        id.to_owned(),
        password.to_owned(),
        local_port,
        interface,
        receiver,
        key,
        token,
        lc,
        remote_host.to_owned(),
        remote_port,
    )
    .await
}
