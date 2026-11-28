//! Configuration, read from the environment in ONE place (`Config::from_env`),
//! plus the one build-time environment read (`REVISION`).
use std::error::Error;
use std::fmt;
use std::net::SocketAddr;
use std::time::Duration;

/// The git revision baked in at build time (`SVC_REVISION`), else `dev`.
/// This is the single allowed `option_env!` in the workspace.
pub const REVISION: &str = match option_env!("SVC_REVISION") {
    Some(r) => r,
    None => "dev",
};

/// Shortest accepted bearer token, in bytes.
pub const MIN_TOKEN_LEN: usize = 16;

/// Resolved configuration.
#[derive(Clone, PartialEq, Eq)]
pub struct Config {
    /// Address the HTTP server binds (`SVC_LISTEN_ADDR`, an `ip:port`).
    pub listen_addr: String,
    /// Log one line per finished span (`SVC_TRACING=log`; `off` is the default).
    pub tracing: bool,
    /// How long shutdown waits for in-flight requests (`SVC_SHUTDOWN_GRACE_MS`).
    pub shutdown_grace: Duration,
    /// Bearer token the write routes require (`SVC_AUTH_TOKEN`, REQUIRED).
    pub auth_token: String,
    /// A non-loopback bind is refused unless `SVC_ALLOW_NON_LOOPBACK=1`.
    pub allow_non_loopback: bool,
    /// Request head must complete within this (`SVC_HEAD_DEADLINE_MS`).
    pub head_deadline: Duration,
    /// Whole request must complete within this (`SVC_REQUEST_DEADLINE_MS`).
    pub request_deadline: Duration,
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Config")
            .field("listen_addr", &self.listen_addr)
            .field("tracing", &self.tracing)
            .field("shutdown_grace", &self.shutdown_grace)
            .field("auth_token", &"<redacted>")
            .field("allow_non_loopback", &self.allow_non_loopback)
            .field("head_deadline", &self.head_deadline)
            .field("request_deadline", &self.request_deadline)
            .finish()
    }
}

/// A variable that is set but unusable, or required and missing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError(pub String);

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "config: {}", self.0)
    }
}

impl Error for ConfigError {}

fn millis<F: Fn(&str) -> Option<String>>(
    get: &F,
    key: &str,
    default: u64,
    range: std::ops::RangeInclusive<u64>,
) -> Result<Duration, ConfigError> {
    let ms = match get(key) {
        None => default,
        Some(v) => v
            .parse::<u64>()
            .map_err(|_| ConfigError(format!("{key}={v:?}: want whole ms")))?,
    };
    if !range.contains(&ms) {
        return Err(ConfigError(format!(
            "{key}={ms}: want {}..={} ms",
            range.start(),
            range.end()
        )));
    }
    Ok(Duration::from_millis(ms))
}

impl Config {
    /// Reads the process environment. The only runtime `std::env` caller.
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    /// Resolves from any lookup, so tests need no process-global state.
    pub fn from_lookup<F: Fn(&str) -> Option<String>>(get: F) -> Result<Self, ConfigError> {
        let listen_addr = get("SVC_LISTEN_ADDR").unwrap_or_else(|| "127.0.0.1:8080".to_owned());
        let bind: SocketAddr = listen_addr.parse().map_err(|_| {
            ConfigError(format!(
                "SVC_LISTEN_ADDR={listen_addr:?}: want a literal ip:port"
            ))
        })?;
        let allow_non_loopback = match get("SVC_ALLOW_NON_LOOPBACK").as_deref() {
            None | Some("0") => false,
            Some("1") => true,
            Some(other) => {
                return Err(ConfigError(format!(
                    "SVC_ALLOW_NON_LOOPBACK={other:?}: want 0|1"
                )))
            }
        };
        if !bind.ip().is_loopback() && !allow_non_loopback {
            return Err(ConfigError(format!(
                "SVC_LISTEN_ADDR={listen_addr}: not a loopback address; there is no TLS here, \
                 put a proxy in front or set SVC_ALLOW_NON_LOOPBACK=1 on purpose"
            )));
        }
        let auth_token = get("SVC_AUTH_TOKEN")
            .ok_or_else(|| ConfigError("SVC_AUTH_TOKEN is required (no default)".to_owned()))?;
        if auth_token.len() < MIN_TOKEN_LEN {
            return Err(ConfigError(format!(
                "SVC_AUTH_TOKEN: want at least {MIN_TOKEN_LEN} bytes"
            )));
        }
        // A request can only present a token made of visible ASCII: HTTP
        // trims leading/trailing whitespace off a header value and forbids
        // control bytes, so any other token could start the service and then
        // never authorise a single write.
        if !auth_token.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
            return Err(ConfigError(
                "SVC_AUTH_TOKEN: only visible ASCII (0x21..0x7E) is allowed, no whitespace, \
                 control or non-ASCII byte"
                    .to_owned(),
            ));
        }
        let tracing = match get("SVC_TRACING").as_deref() {
            None | Some("off") => false,
            Some("log") => true,
            Some(other) => return Err(ConfigError(format!("SVC_TRACING={other:?}: want off|log"))),
        };
        let shutdown_grace =
            match get("SVC_SHUTDOWN_GRACE_MS") {
                None => Duration::from_millis(5_000),
                Some(v) => Duration::from_millis(v.parse::<u64>().map_err(|_| {
                    ConfigError(format!("SVC_SHUTDOWN_GRACE_MS={v:?}: want whole ms"))
                })?),
            };
        let head_deadline = millis(&get, "SVC_HEAD_DEADLINE_MS", 2_000, 100..=60_000)?;
        let request_deadline = millis(&get, "SVC_REQUEST_DEADLINE_MS", 10_000, 100..=60_000)?;
        if head_deadline > request_deadline {
            return Err(ConfigError(
                "SVC_HEAD_DEADLINE_MS must not exceed SVC_REQUEST_DEADLINE_MS".to_owned(),
            ));
        }
        Ok(Self {
            listen_addr,
            tracing,
            shutdown_grace,
            auth_token,
            allow_non_loopback,
            head_deadline,
            request_deadline,
        })
    }

    /// A deterministic fingerprint of the resolved config (FNV-1a, 64 bit).
    /// The token is NOT part of it.
    pub fn digest(&self) -> String {
        let canon = format!(
            "{}|{}|{}|{}|{}|{}",
            self.listen_addr,
            self.tracing,
            self.shutdown_grace.as_millis(),
            self.allow_non_loopback,
            self.head_deadline.as_millis(),
            self.request_deadline.as_millis()
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

    const TOKEN: &str = "0123456789abcdef";

    fn with(pairs: &'static [(&'static str, &'static str)]) -> Result<Config, ConfigError> {
        Config::from_lookup(|k| {
            if k == "SVC_AUTH_TOKEN" && !pairs.iter().any(|(pk, _)| *pk == k) {
                return Some(TOKEN.to_owned());
            }
            pairs
                .iter()
                .find(|(pk, _)| *pk == k)
                .map(|(_, v)| (*v).to_owned())
        })
    }

    #[test]
    fn defaults_apply_when_only_the_token_is_set() {
        let c = with(&[]).unwrap();
        assert_eq!(c.listen_addr, "127.0.0.1:8080");
        assert!(!c.tracing && !c.allow_non_loopback);
        assert_eq!(c.shutdown_grace, Duration::from_secs(5));
        assert_eq!(c.head_deadline, Duration::from_secs(2));
        assert_eq!(c.request_deadline, Duration::from_secs(10));
    }

    #[test]
    fn the_token_is_required_and_at_least_16_bytes() {
        assert!(Config::from_lookup(|_| None).is_err());
        assert!(with(&[("SVC_AUTH_TOKEN", "short")]).is_err());
        assert!(with(&[("SVC_AUTH_TOKEN", "0123456789abcde")]).is_err());
        assert!(with(&[("SVC_AUTH_TOKEN", "0123456789abcdef")]).is_ok());
        assert!(with(&[("SVC_AUTH_TOKEN", "")]).is_err());
    }

    #[test]
    fn a_token_no_request_can_present_is_refused_at_startup() {
        let bad = [
            "                ",
            "\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t",
            "0123456789abcdef ",
            " 0123456789abcdef",
            "0123456789 abcdef",
            "0123456789\u{1}bcdef",
            "0123456789\u{7f}bcdef",
            "0123456789abcdé",
            "0123456789abcdef\n",
        ];
        for t in bad {
            let r = Config::from_lookup(|k| (k == "SVC_AUTH_TOKEN").then(|| t.to_owned()));
            let e = r.expect_err(t);
            assert!(e.0.contains("visible ASCII"), "{t:?}: {e}");
        }
        assert!(with(&[("SVC_AUTH_TOKEN", "!~Az09-._~+/=!~Az09")]).is_ok());
    }

    #[test]
    fn a_non_loopback_bind_needs_the_explicit_switch() {
        for addr in ["0.0.0.0:8080", "10.1.2.3:80", "[::]:80", "192.168.0.1:1"] {
            let lookup = |k: &str| match k {
                "SVC_LISTEN_ADDR" => Some(addr.to_owned()),
                "SVC_AUTH_TOKEN" => Some(TOKEN.to_owned()),
                _ => None,
            };
            assert!(Config::from_lookup(lookup).is_err(), "{addr}");
            let allowed = |k: &str| match k {
                "SVC_ALLOW_NON_LOOPBACK" => Some("1".to_owned()),
                other => lookup(other),
            };
            assert!(Config::from_lookup(allowed).is_ok(), "{addr}");
        }
        assert!(with(&[("SVC_LISTEN_ADDR", "[::1]:9000")]).is_ok());
        assert!(with(&[("SVC_LISTEN_ADDR", "localhost:80")]).is_err());
        assert!(with(&[("SVC_ALLOW_NON_LOOPBACK", "yes")]).is_err());
    }

    #[test]
    fn a_bad_value_is_refused_not_defaulted() {
        assert!(with(&[("SVC_TRACING", "yes")]).is_err());
        assert!(with(&[("SVC_SHUTDOWN_GRACE_MS", "x")]).is_err());
        assert!(with(&[("SVC_HEAD_DEADLINE_MS", "5")]).is_err());
        assert!(with(&[("SVC_REQUEST_DEADLINE_MS", "99999999")]).is_err());
        assert!(with(&[
            ("SVC_HEAD_DEADLINE_MS", "5000"),
            ("SVC_REQUEST_DEADLINE_MS", "4000")
        ])
        .is_err());
    }

    #[test]
    fn the_digest_follows_the_config_and_never_the_token() {
        let a = with(&[]).unwrap();
        let b = with(&[("SVC_TRACING", "log")]).unwrap();
        let c = with(&[("SVC_AUTH_TOKEN", "another-long-token-value")]).unwrap();
        assert_eq!(a.digest(), a.digest());
        assert_ne!(a.digest(), b.digest());
        assert_eq!(a.digest(), c.digest());
    }

    #[test]
    fn debug_output_redacts_the_token() {
        let c = with(&[]).unwrap();
        assert!(!format!("{c:?}").contains(TOKEN));
    }
}
