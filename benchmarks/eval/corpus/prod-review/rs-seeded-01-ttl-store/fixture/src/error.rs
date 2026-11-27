use std::fmt;

#[derive(Debug, PartialEq, Eq)]
#[non_exhaustive]
pub enum StoreError {
    EmptyKey,
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StoreError::EmptyKey => write!(f, "key must not be empty"),
        }
    }
}

impl std::error::Error for StoreError {}
