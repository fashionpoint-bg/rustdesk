use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, RwLock,
};

use hbb_common::{
    bail,
    config::{LocalConfig, READ_TIMEOUT},
    log,
    protobuf::Message as _,
    rendezvous_proto::ConnType,
    timeout, ResultType, Stream,
};
use base::message_proto::*;

use crate::client::{
    handle_hash, handle_login_error, handle_login_from_ui, handle_test_delay, hc_connection,
    Client, Data, Interface, LoginConfigHandler,
};

/// Minimal headless [`Interface`] for the agent. It owns the login config
/// handler, buffers any outbound messages the client core produces, and
/// records login state. No UI, no clipboard, no video.
#[derive(Clone)]
pub struct AgentInterface {
    lc: Arc<RwLock<LoginConfigHandler>>,
    outbox: Arc<Mutex<Vec<Message>>>,
    logged_in: Arc<AtomicBool>,
    login_error: Arc<Mutex<Option<String>>>,
    // The core keeps only username/hostname/platform of PeerInfo; screen tools
    // need the display geometry, so keep it here.
    displays: Arc<Mutex<Vec<DisplayInfo>>>,
}

impl AgentInterface {
    pub(crate) fn new(lc: Arc<RwLock<LoginConfigHandler>>) -> Self {
        Self {
            lc,
            outbox: Arc::new(Mutex::new(Vec::new())),
            logged_in: Arc::new(AtomicBool::new(false)),
            login_error: Arc::new(Mutex::new(None)),
            displays: Arc::new(Mutex::new(Vec::new())),
        }
    }

    fn take_outbox(&self) -> Vec<Message> {
        std::mem::take(&mut *self.outbox.lock().unwrap())
    }

    fn take_login_error(&self) -> Option<String> {
        self.login_error.lock().unwrap().take()
    }
}

/// The agent logs in unattended only: without a password the client core asks
/// the UI for one (or the peer waits for someone to click Accept), and nobody
/// answers. Refuse up front instead of hanging.
pub(crate) fn require_password(id: &str, password: &str) -> ResultType<()> {
    if password.is_empty() {
        bail!(
            "no password for {id}: it is not in a shared address book this account can read, and none was given"
        );
    }
    Ok(())
}

#[async_trait::async_trait]
impl Interface for AgentInterface {
    fn send(&self, data: Data) {
        if let Data::Message(m) = data {
            self.outbox.lock().unwrap().push(m);
        }
    }

    fn msgbox(&self, msgtype: &str, title: &str, text: &str, _link: &str) {
        // Login errors arrive here as well as through handle_login_error.
        if msgtype.contains("error") || msgtype == "re-input-password" || msgtype == "input-password"
        {
            *self.login_error.lock().unwrap() = Some(if text.is_empty() {
                title.to_owned()
            } else {
                format!("{title}: {text}")
            });
        } else {
            log::debug!("msgbox [{msgtype}] {title} {text}");
        }
    }

    fn handle_login_error(&self, err: &str) -> bool {
        *self.login_error.lock().unwrap() = Some(err.to_owned());
        // Non-interactive: never retry, treat every login error as fatal.
        handle_login_error(self.lc.clone(), err, self);
        false
    }

    fn handle_peer_info(&self, pi: PeerInfo) {
        *self.displays.lock().unwrap() = pi.displays.clone();
        self.lc.write().unwrap().handle_peer_info(&pi);
        self.logged_in.store(true, Ordering::SeqCst);
    }

    fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {}

    async fn handle_hash(&self, pass: &str, hash: Hash, peer: &mut Stream) -> bool {
        handle_hash(self.lc.clone(), pass, hash, self, peer).await
    }

    async fn handle_login_from_ui(
        &self,
        os_username: String,
        os_password: String,
        password: String,
        remember: bool,
        peer: &mut Stream,
    ) {
        handle_login_from_ui(self.lc.clone(), os_username, os_password, password, remember, peer)
            .await;
    }

    async fn handle_test_delay(&self, t: TestDelay, peer: &mut Stream) {
        handle_test_delay(t, peer).await;
    }

    fn get_lch(&self) -> Arc<RwLock<LoginConfigHandler>> {
        self.lc.clone()
    }
}

/// A connected, logged-in session with the controlled peer. The caller drives
/// the feature-specific message exchange (terminal, files, …) on `stream`.
pub struct Session {
    pub stream: Stream,
    pub interface: AgentInterface,
}

impl Session {
    /// The peer's platform as reported in its login PeerInfo (e.g. "Linux", "Windows").
    pub fn platform(&self) -> String {
        self.interface.lc.read().unwrap().info.platform.clone()
    }

    /// The peer's displays as reported in its login PeerInfo (remote-control
    /// sessions only): origin and size in the peer's virtual desktop.
    pub fn displays(&self) -> Vec<DisplayInfo> {
        self.interface.displays.lock().unwrap().clone()
    }

    /// Send one protobuf message to the peer.
    pub async fn send(&mut self, msg: Message) -> ResultType<()> {
        self.stream.send(&msg).await
    }

    /// Flush any messages the client core queued through `Interface::send`.
    async fn flush_outbox(&mut self) -> ResultType<()> {
        for m in self.interface.take_outbox() {
            self.stream.send(&m).await?;
        }
        Ok(())
    }

    /// Read the next message from the peer, handling the transport-level
    /// `TestDelay` keepalive transparently. Returns `None` on read timeout.
    pub async fn next_message(&mut self) -> ResultType<Option<Message>> {
        loop {
            self.flush_outbox().await?;
            match timeout(READ_TIMEOUT, self.stream.next()).await {
                Err(_) => return Ok(None),
                Ok(Some(Ok(bytes))) => {
                    let msg = Message::parse_from_bytes(&bytes)?;
                    if let Some(message::Union::TestDelay(t)) = msg.union {
                        self.interface.handle_test_delay(t, &mut self.stream).await;
                        continue;
                    }
                    return Ok(Some(msg));
                }
                Ok(Some(Err(err))) => bail!("connection closed: {err}"),
                Ok(None) => bail!("reset by the peer"),
            }
        }
    }
}

/// Connect to `id` on our server and log in with `password` for `conn_type`,
/// returning the session positioned right after `PeerInfo`.
pub async fn connect_and_login(
    key: &str,
    token: &str,
    id: &str,
    password: &str,
    conn_type: ConnType,
) -> ResultType<Session> {
    require_password(id, password)?;
    // Some client-core reads still look at LocalConfig for the account token.
    if !token.is_empty() {
        LocalConfig::set_option("access_token".to_owned(), token.to_owned());
    }

    let lc = Arc::new(RwLock::new(LoginConfigHandler::default()));
    lc.write().unwrap().initialize(
        id.to_owned(),
        conn_type,
        None,
        false,
        None,
        Some(password.to_owned()),
        None,
    );
    let interface = AgentInterface::new(lc.clone());

    let ((mut stream, direct, _pk, _kcp, _stream_type), (feedback, rendezvous_server)) =
        Client::start(id, key, token, conn_type, interface.clone()).await?;
    interface.update_direct(Some(direct));
    let _keep_hc = hc_connection(feedback, rendezvous_server, token).await;

    loop {
        for m in interface.take_outbox() {
            stream.send(&m).await?;
        }
        match timeout(READ_TIMEOUT, stream.next()).await {
            Err(_) => bail!("timeout while logging in to {id}"),
            Ok(Some(Ok(bytes))) => {
                let msg_in = Message::parse_from_bytes(&bytes)?;
                match msg_in.union {
                    Some(message::Union::Hash(hash)) => {
                        interface.handle_hash("", hash, &mut stream).await;
                        // The core reports "Password Required" through msgbox when it
                        // would wait for UI input; nothing will answer it here.
                        if let Some(err) = interface.take_login_error() {
                            bail!("login to {id} failed: {err}");
                        }
                    }
                    Some(message::Union::LoginResponse(lr)) => match lr.union {
                        Some(login_response::Union::Error(err)) => {
                            interface.handle_login_error(&err);
                            bail!("login to {id} failed: {err}");
                        }
                        Some(login_response::Union::PeerInfo(pi)) => {
                            interface.handle_peer_info(pi);
                            return Ok(Session { stream, interface });
                        }
                        _ => {}
                    },
                    Some(message::Union::TestDelay(t)) => {
                        interface.handle_test_delay(t, &mut stream).await;
                    }
                    _ => {}
                }
            }
            Ok(Some(Err(err))) => bail!("connection to {id} closed: {err}"),
            Ok(None) => bail!("connection to {id} reset by the peer"),
        }
    }
}
