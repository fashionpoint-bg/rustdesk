// FashionPoint: pairs a clinic computer with the FashionPoint website (fp-remote docs/pairing.md).
//
// The console requires deployment, so until a computer is deployed the rendezvous server answers its
// registration with NOT_DEPLOYED (rendezvous_mediator::NEEDS_DEPLOY). A person at the computer then types
// a one-time code from their FashionPoint profile. The process that owns the ID, the keys and the
// password (the one that runs the IPC server and the rendezvous mediator) gives the computer a new
// random permanent password and sends it with the code to the website, which deploys the computer in
// the console and puts it into the clinic's address book with that password.
//
// The password is set before the request, so an answer lost on the way back still leaves the computer
// and the address book with the same password.

use crate::rendezvous_mediator::{RendezvousMediator, NEEDS_DEPLOY};
use hbb_common::{
    config::Config,
    log,
    rand::{self, Rng},
    tokio,
};
use serde_derive::{Deserialize, Serialize};
use std::{sync::atomic::Ordering, time::Duration};

/// The website's pairing URL. The clinic edition sets it in default-settings; an administrator can
/// point a test computer at a test website with `FPRemote --option fp-pair-url <url>`.
pub const OPTION_PAIR_URL: &str = "fp-pair-url";
/// The IPC config name the UI asks to learn whether to show the pairing card.
pub const CONFIG_NEEDS_PAIRING: &str = "fp-needs-pairing";

// The same alphabet and length as the clinic install scripts (FPRemote-Clinic-Install*.ps1/.sh).
const PASSWORD_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
const PASSWORD_LENGTH: usize = 24;
// The website deploys the computer and adds it to the address book, two console calls, before it answers.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);
/// How long the UI waits for the pairing result over IPC: the request timeout plus room for the rest.
pub const UI_TIMEOUT_MS: u64 = 60_000;
const MAX_CODE_LENGTH: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairOutcome {
    /// The website registered the computer; `alias` is its name in the address book.
    Paired,
    /// The code is wrong, used or expired (404).
    WrongCode,
    /// The console has this computer's ID on another computer (409).
    IdTaken,
    /// Too many attempts from this address (429).
    TooManyAttempts,
    /// The website or the console failed or refused.
    WebsiteError,
    /// The website could not be reached.
    NoConnection,
    /// This build or computer cannot pair: no pairing URL, or the permanent password cannot be changed.
    NotConfigured,
    /// The FPRemote service did not answer the window.
    ServiceUnavailable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairResult {
    pub outcome: PairOutcome,
    pub alias: String,
}

impl PairResult {
    fn failed(outcome: PairOutcome) -> Self {
        Self {
            outcome,
            alias: String::new(),
        }
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

lazy_static::lazy_static! {
    // One pairing at a time: a second request waits for the first instead of replacing its password.
    static ref PAIRING: tokio::sync::Mutex<()> = tokio::sync::Mutex::new(());
}

/// Whether the console waits for this computer to be deployed and this build can pair it.
/// Runs in the process that owns the rendezvous mediator.
pub fn needs_pairing() -> bool {
    NEEDS_DEPLOY.load(Ordering::SeqCst) && pair_url().is_some()
}

/// Pairs the computer with `code`. Runs in the process that owns the ID, the keys and the password.
pub async fn pair(code: String) -> PairResult {
    let _one_at_a_time = PAIRING.lock().await;
    let Some(url) = pair_url() else {
        log::warn!("FPRemote pairing: no usable {} option", OPTION_PAIR_URL);
        return PairResult::failed(PairOutcome::NotConfigured);
    };
    let Some(code) = normalize_code(&code) else {
        return PairResult::failed(PairOutcome::WrongCode);
    };
    let password = new_password();
    if !Config::set_permanent_password(&password) {
        log::error!("FPRemote pairing: the permanent password cannot be changed");
        return PairResult::failed(PairOutcome::NotConfigured);
    }
    let body = request_body(&code, &password).to_string();
    let answer = tokio::time::timeout(
        REQUEST_TIMEOUT,
        crate::common::post_request_with_status(url, body, ""),
    )
    .await;
    let result = match answer {
        Ok(Ok((status, text))) => result_of(status, &text),
        Ok(Err(err)) => {
            log::warn!("FPRemote pairing: the request failed: {}", err);
            PairResult::failed(PairOutcome::NoConnection)
        }
        Err(_) => {
            log::warn!("FPRemote pairing: no answer in {:?}", REQUEST_TIMEOUT);
            PairResult::failed(PairOutcome::NoConnection)
        }
    };
    if result.outcome == PairOutcome::Paired {
        log::info!("FPRemote pairing: paired as \"{}\"", result.alias);
        // As Data::Deployed: register again now instead of waiting out the not-deployed backoff.
        NEEDS_DEPLOY.store(false, Ordering::SeqCst);
        RendezvousMediator::restart();
    } else {
        log::warn!("FPRemote pairing: {:?}", result.outcome);
    }
    result
}

/// The website URL, or None when it is not set or would send the password unencrypted.
fn pair_url() -> Option<String> {
    let url = Config::get_option(OPTION_PAIR_URL);
    let url = url.trim();
    if url.starts_with("https://") || is_local_http(url) {
        Some(url.to_owned())
    } else {
        None
    }
}

// Plain HTTP only to this computer itself, for testing against a website on it.
fn is_local_http(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("http://") else {
        return false;
    };
    let host = rest.split(['/', ':']).next().unwrap_or_default();
    host == "localhost" || host == "127.0.0.1"
}

/// The code as the website issues it: no spaces or dashes, upper case. None when nothing usable is left.
fn normalize_code(code: &str) -> Option<String> {
    let code: String = code
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .flat_map(char::to_uppercase)
        .collect();
    if code.is_empty() || code.chars().count() > MAX_CODE_LENGTH {
        None
    } else {
        Some(code)
    }
}

fn new_password() -> String {
    let mut rng = rand::thread_rng();
    (0..PASSWORD_LENGTH)
        .map(|_| PASSWORD_ALPHABET[rng.gen_range(0..PASSWORD_ALPHABET.len())] as char)
        .collect()
}

fn request_body(code: &str, password: &str) -> serde_json::Value {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let os_username = {
        let username = crate::platform::get_active_username();
        if cfg!(windows) && username == "SYSTEM" {
            String::new()
        } else {
            username
        }
    };
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let os_username = String::new();
    let id = Config::get_id();
    // The website requires a computer name; the ID stands in on the rare system that reports none.
    let hostname = match crate::common::hostname().trim() {
        "" => id.clone(),
        name => name.to_owned(),
    };
    serde_json::json!({
        "code": code,
        "deviceId": id,
        "uuid": crate::encode64(hbb_common::get_uuid()),
        "publicKey": crate::encode64(Config::get_key_pair().1),
        "password": password,
        "hostname": hostname,
        "platform": hbb_common::whoami::platform().to_string(),
        "osUsername": os_username,
        "version": crate::VERSION,
    })
}

fn result_of(status: u16, text: &str) -> PairResult {
    match status {
        200 | 201 => {
            let alias = serde_json::from_str::<serde_json::Value>(text)
                .ok()
                .and_then(|v| v["alias"].as_str().map(str::to_owned))
                .unwrap_or_default();
            PairResult {
                outcome: PairOutcome::Paired,
                alias,
            }
        }
        404 => PairResult::failed(PairOutcome::WrongCode),
        409 => PairResult::failed(PairOutcome::IdTaken),
        429 => PairResult::failed(PairOutcome::TooManyAttempts),
        _ => {
            log::warn!(
                "FPRemote pairing: the website answered {}: {}",
                status,
                text.chars().take(300).collect::<String>()
            );
            PairResult::failed(PairOutcome::WebsiteError)
        }
    }
}

/// The window's side: whether to show the pairing card, asked from the service over IPC.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn needs_pairing_from_ui() -> bool {
    matches!(
        crate::ipc::get_config(CONFIG_NEEDS_PAIRING),
        Ok(Some(v)) if v == "Y"
    )
}

/// The window's side: asks the service to pair the computer with `code`.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn pair_from_ui(code: String) -> PairResult {
    match crate::ipc::fp_pair(code) {
        Ok(result) => {
            if result.outcome == PairOutcome::Paired {
                // As after `--password`: this process's copy of the password storage follows the service's.
                if let Err(err) = crate::ipc::sync_permanent_password_storage_from_daemon() {
                    log::warn!("FPRemote pairing: password storage not synced: {}", err);
                }
            }
            result
        }
        Err(err) => {
            log::warn!("FPRemote pairing: the service did not answer: {}", err);
            PairResult::failed(PairOutcome::ServiceUnavailable)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_is_normalized_as_the_website_issues_it() {
        assert_eq!(normalize_code(" k7m2-qx9p ").as_deref(), Some("K7M2QX9P"));
        assert_eq!(normalize_code("K7M2 QX9P").as_deref(), Some("K7M2QX9P"));
        assert_eq!(normalize_code(" - "), None);
        assert_eq!(normalize_code(&"A".repeat(MAX_CODE_LENGTH + 1)), None);
    }

    #[test]
    fn password_uses_the_install_scripts_alphabet() {
        let password = new_password();
        assert_eq!(password.len(), PASSWORD_LENGTH);
        assert!(password.bytes().all(|b| PASSWORD_ALPHABET.contains(&b)));
        assert_ne!(password, new_password());
    }

    #[test]
    fn plain_http_only_to_this_computer() {
        assert!(is_local_http("http://localhost:18080/api-platform/fpremote/pair"));
        assert!(is_local_http("http://127.0.0.1/pair"));
        assert!(!is_local_http("http://fashionpoint.bg/pair"));
        assert!(!is_local_http("http://localhost.evil.example/pair"));
        assert!(!is_local_http("https://localhost/pair"));
    }

    #[test]
    fn website_answers_map_to_outcomes() {
        let paired = result_of(201, r#"{"alias":"Clinic - Ivan - RECEPTION"}"#);
        assert_eq!(paired.outcome, PairOutcome::Paired);
        assert_eq!(paired.alias, "Clinic - Ivan - RECEPTION");
        assert_eq!(result_of(404, "{}").outcome, PairOutcome::WrongCode);
        assert_eq!(result_of(409, "{}").outcome, PairOutcome::IdTaken);
        assert_eq!(result_of(429, "{}").outcome, PairOutcome::TooManyAttempts);
        assert_eq!(result_of(422, "{}").outcome, PairOutcome::WebsiteError);
        assert_eq!(result_of(502, "").outcome, PairOutcome::WebsiteError);
        assert_eq!(result_of(503, "").outcome, PairOutcome::WebsiteError);
    }

    #[test]
    fn result_travels_to_the_window_as_json() {
        let result = PairResult {
            outcome: PairOutcome::TooManyAttempts,
            alias: String::new(),
        };
        assert_eq!(
            result.to_json(),
            r#"{"outcome":"too_many_attempts","alias":""}"#
        );
    }
}
