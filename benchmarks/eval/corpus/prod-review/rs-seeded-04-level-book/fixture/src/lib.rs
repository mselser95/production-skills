//! Price-level order book kept from a stream of level updates.

mod book;

pub use book::{OrderBook, Side, Update};
