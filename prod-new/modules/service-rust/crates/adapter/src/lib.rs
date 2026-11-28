//! Adapter zone: the far side of the ports. Depends on `app` and `domain`
//! (Cargo enforces it): it cannot name `platform`.
#![forbid(unsafe_code)]

pub mod http;
pub mod memory;
