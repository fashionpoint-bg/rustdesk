use hbb_common::{bail, config::Config, log, ResultType};
use serde_derive::Deserialize;
use serde_json::{json, Value};
use totp_rs::{Algorithm, Secret, TOTP};

use super::config::AgentConfig;

/// One managed computer as the shared address book sees it.
#[derive(Debug, Clone, Deserialize)]
pub struct Peer {
    #[serde(default, deserialize_with = "null_as_empty")]
    pub id: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub alias: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub username: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub hostname: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub platform: String,
    #[serde(default, deserialize_with = "null_as_empty")]
    pub device_group_name: String,
    // The stored device password this account may use to connect. Never logged.
    #[serde(default, deserialize_with = "null_as_empty")]
    pub password: String,
}

/// The API sends `null` for what a computer has not reported yet: one added to
/// the book at install has no platform, hostname or username until it first
/// connects. `#[serde(default)]` covers only a missing field, so such an entry
/// failed to parse and the computer could not be reached (seen 13.10.2026).
fn null_as_empty<'de, D: serde::Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(<Option<String> as serde::Deserialize>::deserialize(d)?.unwrap_or_default())
}

/// A logged-in session on the Pro API. The access token also authorizes P2P
/// connections when the server requires login on the controlling side.
pub struct ProSession {
    api: String,
    http: reqwest::Client,
    device_id: String,
    device_uuid: String,
    pub token: String,
}

fn totp_now(secret: &str) -> ResultType<String> {
    let bytes = Secret::Encoded(secret.to_owned())
        .to_bytes()
        .map_err(|e| hbb_common::anyhow::anyhow!("bad TOTP secret: {:?}", e))?;
    let totp = TOTP::new_unchecked(Algorithm::SHA1, 6, 1, 30, bytes, None, String::new());
    Ok(totp.generate_current()?)
}

/// The server refused the 2FA step. A separate type so `login` retries only
/// this: two logins of one account from one machine at the same moment clash
/// on the server's pending-2FA state and one of them is refused (seen with
/// parallel CLI calls, 13.10.2026; logins one after another all pass).
#[derive(Debug)]
struct TfaRejected(String);

impl std::fmt::Display for TfaRejected {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "2FA rejected: {}", self.0)
    }
}

impl std::error::Error for TfaRejected {}

fn device_info(name: &str) -> Value {
    json!({ "os": "linux", "type": "client", "name": name })
}

impl ProSession {
    /// Log in, retrying a refused 2FA step after a short random pause so that
    /// agent processes started together on one machine all get in.
    pub async fn login(cfg: &AgentConfig) -> ResultType<Self> {
        const ATTEMPTS: u32 = 4;
        let mut attempt = 1;
        loop {
            match Self::login_once(cfg).await {
                Err(e) if attempt < ATTEMPTS && e.downcast_ref::<TfaRejected>().is_some() => {
                    let ms = 300 + hbb_common::rand::random::<u64>() % 1200;
                    log::info!("{e} (attempt {attempt}/{ATTEMPTS}); retrying in {ms} ms");
                    hbb_common::sleep(ms as f32 / 1000.).await;
                    attempt += 1;
                }
                result => return result,
            }
        }
    }

    /// One login with the account password and a generated 2FA code. The
    /// server answers the first request with `email_check` + `tfa_check`; the
    /// second request carries the TOTP code and the returned secret.
    async fn login_once(cfg: &AgentConfig) -> ResultType<Self> {
        let password = cfg.read_secret("password")?;
        let totp_secret = cfg.read_secret("totp")?;
        let device_id = Config::get_id();
        let device_uuid = crate::ui_interface::get_uuid();
        let http = reqwest::Client::builder().build()?;
        let url = format!("{}/api/login", cfg.api.trim_end_matches('/'));

        let step1: Value = http
            .post(&url)
            .json(&json!({
                "username": cfg.username,
                "password": password,
                "id": device_id,
                "uuid": device_uuid,
                "autoLogin": true,
                "type": "account",
                "deviceInfo": device_info(&device_id),
            }))
            .send()
            .await?
            .json()
            .await?;
        if let Some(err) = step1.get("error").and_then(|v| v.as_str()) {
            bail!("login rejected: {}", err);
        }

        let mut token = step1
            .get("access_token")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_owned();

        // 2FA step, when the account enforces it (our agent account does).
        if token.is_empty() && step1.get("type").and_then(|v| v.as_str()) == Some("email_check") {
            let secret = step1.get("secret").and_then(|v| v.as_str()).unwrap_or_default();
            let code = totp_now(&totp_secret)?;
            let step2: Value = http
                .post(&url)
                .json(&json!({
                    "username": cfg.username,
                    "id": device_id,
                    "uuid": device_uuid,
                    "autoLogin": true,
                    "type": "email_code",
                    "verificationCode": code,
                    "tfaCode": code,
                    "secret": secret,
                    "deviceInfo": device_info(&device_id),
                }))
                .send()
                .await?
                .json()
                .await?;
            if let Some(err) = step2.get("error").and_then(|v| v.as_str()) {
                return Err(TfaRejected(err.to_owned()).into());
            }
            token = step2
                .get("access_token")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_owned();
        }

        if token.is_empty() {
            bail!("no access token returned");
        }
        Ok(Self {
            api: cfg.api.trim_end_matches('/').to_owned(),
            http,
            device_id,
            device_uuid,
            token,
        })
    }

    async fn post_paged(&self, path: &str, extra: &[(&str, &str)]) -> ResultType<Vec<Value>> {
        let mut out = Vec::new();
        let mut current = 1;
        loop {
            let mut req = self
                .http
                .post(format!("{}{}", self.api, path))
                .bearer_auth(&self.token)
                .query(&[
                    ("current", current.to_string()),
                    ("pageSize", "100".to_owned()),
                ]);
            for (k, v) in extra {
                req = req.query(&[(*k, *v)]);
            }
            let resp = req.header("Content-Type", "application/json").send().await?;
            if resp.status().as_u16() == 404 {
                break;
            }
            let body: Value = resp.json().await?;
            if let Some(err) = body.get("error").and_then(|v| v.as_str()) {
                bail!("{} failed: {}", path, err);
            }
            let data = body.get("data").and_then(|v| v.as_array()).cloned().unwrap_or_default();
            let got = data.len();
            out.extend(data);
            let total = body.get("total").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            if got == 0 || out.len() >= total {
                break;
            }
            current += 1;
        }
        Ok(out)
    }

    /// Every managed computer this account can reach through shared address
    /// books, with the password each carries.
    pub async fn devices(&self) -> ResultType<Vec<Peer>> {
        let profiles = self.post_paged("/api/ab/shared/profiles", &[]).await?;
        let mut peers = Vec::new();
        for profile in profiles {
            let Some(guid) = profile.get("guid").and_then(|v| v.as_str()) else {
                continue;
            };
            for raw in self.post_paged("/api/ab/peers", &[("ab", guid)]).await? {
                let id = raw.get("id").and_then(|v| v.as_str()).unwrap_or("?").to_owned();
                match serde_json::from_value::<Peer>(raw) {
                    Ok(peer) => peers.push(peer),
                    // Not the error text: it can quote a field, and the entry
                    // carries the computer's password.
                    Err(_) => log::warn!("address book entry {id} does not parse, skipped"),
                }
            }
        }
        Ok(peers)
    }

    pub async fn logout(&self) -> ResultType<()> {
        self.http
            .post(format!("{}/api/logout", self.api))
            .bearer_auth(&self.token)
            .json(&json!({ "id": self.device_id, "uuid": self.device_uuid }))
            .send()
            .await?;
        Ok(())
    }
}
