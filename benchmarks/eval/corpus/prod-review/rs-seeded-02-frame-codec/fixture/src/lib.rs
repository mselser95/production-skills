//! Length-prefixed frames with a one-byte checksum.
//!
//! Wire format: `[len: u16 big-endian][payload: len bytes][sum: u8]`.

mod frame;
mod stream;

pub use frame::{checksum, decode, FrameError, HEADER_LEN};
pub use stream::decode_all;
