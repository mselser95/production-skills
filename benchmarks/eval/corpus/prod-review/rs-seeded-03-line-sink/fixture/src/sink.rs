use std::io::{self, Write};

use crate::point::Point;

/// Writes points to `out` and counts the ones it accepted.
pub struct Sink<W: Write> {
    out: W,
    written: u64,
}

impl<W: Write> Sink<W> {
    pub fn new(out: W) -> Self {
        Sink { out, written: 0 }
    }

    pub fn write_point(&mut self, p: &Point) -> io::Result<()> {
        let line = p.to_line()?;
        self.out.write_all(line.as_bytes())?;
        self.written += 1;
        Ok(())
    }

    pub fn written(&self) -> u64 {
        self.written
    }

    pub fn into_inner(self) -> W {
        self.out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_points_in_order() {
        let mut sink = Sink::new(Vec::new());
        sink.write_point(&Point::new("a", 1, 10)).unwrap();
        sink.write_point(&Point::new("b", 2, 20)).unwrap();
        assert_eq!(sink.written(), 2);
        assert_eq!(
            String::from_utf8(sink.into_inner()).unwrap(),
            "a 1 10\nb 2 20\n"
        );
    }

    #[test]
    fn a_refused_point_is_not_counted() {
        let mut sink = Sink::new(Vec::new());
        assert!(sink.write_point(&Point::new("", 1, 10)).is_err());
        assert_eq!(sink.written(), 0);
    }
}
