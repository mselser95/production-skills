//! A small in-memory key/value store whose entries expire.

mod error;
mod store;

pub use error::StoreError;
pub use store::Store;
