//! Configuration, read from the environment in ONE place (`Config::from_env`).
use std::error::Error;
use std::fmt;
use std::time::Duration;

/// Resolved configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// Address the HTTP server binds (`SVC_LISTEN_ADDR`).
    pub listen_addr: String,
    /// Log one line per finished span (`SVC_TRACING=log`; `off` is the default).
    pub tracing: bool,
    /// How long shutdown waits for in-flight requests (`SVC_SHUTDOWN_GRACE_MS`).
    pub shutdown_grace: Duration,
}

/// A variable that is set but unusable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError(pub String);

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "config: {}", self.0)
    }
}

impl Error for ConfigError {}

impl Config {
    /// Reads the process environment. The only `std::env` caller in the crate.
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    /// Resolves from any lookup, so tests need no process-global state.
    pub fn from_lookup<F: Fn(&str) -> Option<String>>(get: F) -> Result<Self, ConfigError> {
        let listen_addr = get("SVC_LISTEN_ADDR").unwrap_or_else(|| "127.0.0.1:8080".to_owned());
        let tracing = match get("SVC_TRACING").as_deref() {
            None | Some("off") => false,
            Some("log") => true,
            Some(other) => return Err(ConfigError(format!("SVC_TRACING={other:?}: want off|log"))),
        };
        let grace_ms = match get("SVC_SHUTDOWN_GRACE_MS") {
            None => 5_000,
            Some(v) => v
                .parse::<u64>()
                .map_err(|_| ConfigError(format!("SVC_SHUTDOWN_GRACE_MS={v:?}: want whole ms")))?,
        };
        Ok(Self {
            listen_addr,
            tracing,
            shutdown_grace: Duration::from_millis(grace_ms),
        })
    }

    /// A deterministic fingerprint of the resolved config (FNV-1a, 64 bit).
    pub fn digest(&self) -> String {
        let canon = format!(
            "{}|{}|{}",
            self.listen_addr,
            self.tracing,
            self.shutdown_grace.as_millis()
        );
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in canon.bytes() {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x0100_0000_01b3);
        }
        format!("{h:016x}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_apply_when_nothing_is_set() {
        let c = Config::from_lookup(|_| None).unwrap();
        assert_eq!(c.listen_addr, "127.0.0.1:8080");
        assert!(!c.tracing);
        assert_eq!(c.shutdown_grace, Duration::from_secs(5));
    }

    #[test]
    fn a_bad_value_is_refused_not_defaulted() {
        assert!(Config::from_lookup(|k| (k == "SVC_TRACING").then(|| "yes".to_owned())).is_err());
        assert!(
            Config::from_lookup(|k| (k == "SVC_SHUTDOWN_GRACE_MS").then(|| "x".to_owned()))
                .is_err()
        );
    }

    #[test]
    fn the_digest_follows_the_config() {
        let a = Config::from_lookup(|_| None).unwrap();
        let b = Config::from_lookup(|k| (k == "SVC_TRACING").then(|| "log".to_owned())).unwrap();
        assert_eq!(a.digest(), a.digest());
        assert_ne!(a.digest(), b.digest());
    }
}
