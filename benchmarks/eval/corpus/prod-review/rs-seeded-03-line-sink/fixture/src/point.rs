use std::io;

/// One metric sample: `<name> <value> <timestamp_ms>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Point {
    pub name: String,
    pub value: i64,
    pub ts_ms: u64,
}

impl Point {
    pub fn new(name: &str, value: i64, ts_ms: u64) -> Self {
        Point {
            name: name.to_string(),
            value,
            ts_ms,
        }
    }

    /// The point as one newline-terminated line. A name that is empty or holds
    /// whitespace would corrupt the format, so it is refused.
    pub fn to_line(&self) -> io::Result<String> {
        if self.name.is_empty() || self.name.chars().any(char::is_whitespace) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "point name must be non-empty and free of whitespace",
            ));
        }
        Ok(format!("{} {} {}\n", self.name, self.value, self.ts_ms))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_a_line() {
        let p = Point::new("cpu.load", -3, 1700);
        assert_eq!(p.to_line().unwrap(), "cpu.load -3 1700\n");
    }

    #[test]
    fn bad_names_are_refused() {
        assert!(Point::new("", 1, 1).to_line().is_err());
        assert!(Point::new("a b", 1, 1).to_line().is_err());
    }
}
