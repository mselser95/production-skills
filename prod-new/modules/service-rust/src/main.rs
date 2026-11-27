//! Composition root: the only file that sees every zone. Reads config once,
//! wires ports to adapters, serves, and shuts down on SIGINT/SIGTERM.
#![forbid(unsafe_code)]

use std::error::Error;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use svc::adapter::{http::Server, memory::MemoryStore};
use svc::app::{Clock, IdGenerator, Ledger, MetricsSource, Telemetry};
use svc::platform::{
    buildinfo, clock::SystemClock, config::Config, ids::Sequence, shutdown, telemetry::Recorder,
};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("fatal: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let config = Config::from_env()?;
    let clock: Arc<dyn Clock> = Arc::new(SystemClock);
    let recorder = Arc::new(Recorder::new(config.tracing));
    let telemetry: Arc<dyn Telemetry> = recorder.clone();
    let metrics: Arc<dyn MetricsSource> = recorder;
    let ids: Arc<dyn IdGenerator> = Arc::new(Sequence::new(&clock));

    telemetry.gauge_set(
        "svc_build_info",
        1,
        &[
            ("revision", buildinfo::revision()),
            ("config_digest", &config.digest()),
        ],
    );

    let ledger = Arc::new(Ledger::new(
        Arc::new(MemoryStore::new()),
        telemetry.clone(),
        clock,
    ));
    let server = Server::bind(&config.listen_addr, ledger, ids, telemetry, metrics)?;

    let stop = Arc::new(AtomicBool::new(false));
    shutdown::install(stop.clone())?;
    eprintln!(
        "{} listening on {}",
        buildinfo::SERVICE_NAME,
        server.local_addr()?
    );

    let left = server.serve(&stop, config.shutdown_grace);
    eprintln!(
        "{} stopped; {left} request(s) abandoned at the grace deadline",
        buildinfo::SERVICE_NAME
    );
    Ok(())
}
