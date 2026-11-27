use std::fmt;

/// Bytes taken by the length prefix.
pub const HEADER_LEN: usize = 2;

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    Truncated,
    BadChecksum { expected: u8, found: u8 },
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FrameError::Truncated => write!(f, "frame is truncated"),
            FrameError::BadChecksum { expected, found } => {
                write!(
                    f,
                    "bad checksum: expected {expected:#04x}, found {found:#04x}"
                )
            }
        }
    }
}

impl std::error::Error for FrameError {}

/// Sum of the payload bytes, modulo 256.
pub fn checksum(payload: &[u8]) -> u8 {
    payload.iter().fold(0u8, |acc, b| acc.wrapping_add(*b))
}

/// Decode one frame from the front of `buf`: the payload and the bytes consumed.
pub fn decode(buf: &[u8]) -> Result<(&[u8], usize), FrameError> {
    if buf.len() < HEADER_LEN {
        return Err(FrameError::Truncated);
    }
    let len = u16::from_be_bytes([buf[0], buf[1]]) as usize;
    let end = HEADER_LEN + len;
    if buf.len() < end + 1 {
        return Err(FrameError::Truncated);
    }
    let payload = &buf[HEADER_LEN..end];
    let expected = checksum(payload);
    let found = buf[end];
    if found != expected {
        return Err(FrameError::BadChecksum { expected, found });
    }
    Ok((payload, end + 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_frame() {
        let buf = [0, 3, 1, 2, 3, 6];
        assert_eq!(decode(&buf), Ok((&[1u8, 2, 3][..], 6)));
    }

    #[test]
    fn short_buffer_is_truncated() {
        assert_eq!(decode(&[0]), Err(FrameError::Truncated));
        assert_eq!(decode(&[0, 3, 1, 2]), Err(FrameError::Truncated));
    }

    #[test]
    fn wrong_checksum_is_reported() {
        let buf = [0, 2, 9, 9, 17];
        assert_eq!(
            decode(&buf),
            Err(FrameError::BadChecksum {
                expected: 18,
                found: 17
            })
        );
    }
}
