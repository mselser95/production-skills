//! Writes metric points as text lines to any `io::Write`.

mod point;
mod sink;

pub use point::Point;
pub use sink::Sink;
