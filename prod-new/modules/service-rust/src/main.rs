//! Composition root: the only file that sees every zone. Reads config once,
//! wires ports to adapters, serves, and shuts down on SIGINT/SIGTERM.
//!
//! Exit codes: 0 drained cleanly, 1 failed to start, 3 requests were still
//! running when the shutdown grace expired.
#![forbid(unsafe_code)]

use std::error::Error;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use svc_adapter::{
    http::{Options, Server},
    memory::MemoryStore,
};
use svc_app::{Clock, Gauge, IdGenerator, Ledger, MetricsSource, Telemetry};
use svc_platform::{
    buildinfo, clock::SystemClock, config::Config, ids::Sequence, shutdown, telemetry::Recorder,
};

/// Requests were abandoned at the grace deadline.
const EXIT_ABANDONED: u8 = 3;

fn main() -> ExitCode {
    match run() {
        Ok(0) => ExitCode::SUCCESS,
        Ok(_) => ExitCode::from(EXIT_ABANDONED),
        Err(e) => {
            eprintln!("fatal: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<usize, Box<dyn Error>> {
    let config = Config::from_env()?;
    let clock: Arc<dyn Clock> = Arc::new(SystemClock);
    let recorder = Arc::new(Recorder::new(config.tracing));
    let telemetry: Arc<dyn Telemetry> = recorder.clone();
    let metrics: Arc<dyn MetricsSource> = recorder;
    let ids: Arc<dyn IdGenerator> = Arc::new(Sequence::new(&clock));

    telemetry.gauge_set(
        Gauge::BuildInfo,
        1,
        &[buildinfo::revision(), &config.digest()],
    );

    let ledger = Arc::new(Ledger::new(
        Arc::new(MemoryStore::new()),
        telemetry.clone(),
        clock,
    ));
    let mut options = Options::new(config.auth_token.clone());
    options.head_deadline = config.head_deadline;
    options.request_deadline = config.request_deadline;
    let server = Server::bind(
        &config.listen_addr,
        ledger,
        ids,
        telemetry,
        metrics,
        options,
    )?;

    let stop = Arc::new(AtomicBool::new(false));
    shutdown::install(stop.clone())?;
    eprintln!(
        "{} listening on {}",
        buildinfo::SERVICE_NAME,
        server.local_addr()?
    );

    // `serve` closes the listener the moment `stop` is set, then drains.
    let left = server.serve(&stop, config.shutdown_grace);
    eprintln!(
        "{} stopped; {left} request(s) abandoned at the grace deadline",
        buildinfo::SERVICE_NAME
    );
    Ok(left)
}
