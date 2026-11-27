use crate::frame::{decode, FrameError};

/// Split a buffer holding back-to-back frames into their payloads.
pub fn decode_all(mut buf: &[u8]) -> Result<Vec<Vec<u8>>, FrameError> {
    let mut out = Vec::new();
    while !buf.is_empty() {
        let (payload, used) = decode(buf)?;
        out.push(payload.to_vec());
        buf = &buf[used..];
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_two_frames() {
        let buf = [0, 1, 7, 7, 0, 2, 1, 1, 2];
        assert_eq!(decode_all(&buf), Ok(vec![vec![7], vec![1, 1]]));
    }

    #[test]
    fn trailing_garbage_is_an_error() {
        let buf = [0, 1, 7, 7, 0];
        assert_eq!(decode_all(&buf), Err(FrameError::Truncated));
    }
}
