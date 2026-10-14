use std::{fs, path::PathBuf};

use hbb_common::{bail, config::Config, toml, ResultType};
use serde_derive::{Deserialize, Serialize};

// Coordinates of FashionPoint's own RustDesk Server Pro. These are public
// connection facts, not secrets: the key is the server's published public key,
// the same one a clinic client is built with. They are written into a config
// file on first run so an operator can point the agent at another server
// without a rebuild.
const DEFAULT_HOST: &str = "rustdesk.fashionpoint.bg";
const DEFAULT_KEY: &str = "R6i2dRl9Mu+PoQhZ1bDdRmJigvKlvzI3BuPYNKPNtkY=";
const DEFAULT_RELAY: &str = "rustdesk.fashionpoint.bg";
const DEFAULT_API: &str = "https://rustdesk.fashionpoint.bg";
const DEFAULT_USERNAME: &str = "agent";

pub const APP_NAME: &str = "fpremote-agent";

/// Who is connected, as the clinic computer's FPRemote panel shows it while the
/// agent is in (LoginRequest my_name; the client core capitalises each word).
const DISPLAY_NAME: &str = "FashionPoint агент";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    pub host: String,
    pub key: String,
    pub relay: String,
    pub api: String,
    pub username: String,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            host: DEFAULT_HOST.to_owned(),
            key: DEFAULT_KEY.to_owned(),
            relay: DEFAULT_RELAY.to_owned(),
            api: DEFAULT_API.to_owned(),
            username: DEFAULT_USERNAME.to_owned(),
        }
    }
}

fn fp_dir() -> ResultType<PathBuf> {
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        bail!("HOME is not set");
    }
    Ok(PathBuf::from(home).join(".config").join("fashionpoint"))
}

impl AgentConfig {
    pub fn config_path() -> ResultType<PathBuf> {
        Ok(fp_dir()?.join("fpremote-agent.toml"))
    }

    /// Load the agent config, creating it from built-in defaults on first run.
    pub fn load() -> ResultType<Self> {
        let path = Self::config_path()?;
        if path.exists() {
            let text = fs::read_to_string(&path)?;
            Ok(toml::from_str(&text)?)
        } else {
            let cfg = Self::default();
            fs::create_dir_all(fp_dir()?)?;
            fs::write(&path, toml::to_string_pretty(&cfg)?)?;
            Ok(cfg)
        }
    }

    /// Read a secret kept beside the account (mode 600 files), e.g. the
    /// password or TOTP seed. Returns the trimmed contents.
    pub fn read_secret(&self, suffix: &str) -> ResultType<String> {
        let path = fp_dir()?.join(format!("rustdesk-user-{}.{}", self.username, suffix));
        let text = fs::read_to_string(&path)
            .map_err(|e| hbb_common::anyhow::anyhow!("cannot read {}: {}", path.display(), e))?;
        Ok(text.trim().to_owned())
    }

    /// Append one JSON line to the agent's audit log. Every peer-affecting MCP
    /// call is recorded here so there is a record of what the agent did.
    pub fn append_audit(entry: &str) {
        if let Ok(dir) = fp_dir() {
            let _ = fs::create_dir_all(&dir);
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join("fpremote-agent-audit.log"))
            {
                use std::io::Write as _;
                let _ = writeln!(f, "{entry}");
            }
        }
    }

    /// Point the embedded RustDesk client at our server before any connection.
    /// A standalone binary with no running service reads these straight from
    /// its own config file.
    pub fn bootstrap(&self) {
        *hbb_common::config::APP_NAME.write().unwrap() = APP_NAME.to_owned();
        Config::set_option("key".to_owned(), self.key.clone());
        Config::set_option("custom-rendezvous-server".to_owned(), self.host.clone());
        Config::set_option("relay-server".to_owned(), self.relay.clone());
        Config::set_option("api-server".to_owned(), self.api.clone());
        hbb_common::config::BUILTIN_SETTINGS.write().unwrap().insert(
            base::config::keys::OPTION_DISPLAY_NAME.to_owned(),
            DISPLAY_NAME.to_owned(),
        );
    }
}
