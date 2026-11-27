use std::collections::HashMap;
use std::sync::Mutex;

use crate::error::StoreError;

struct Entry {
    value: String,
    expires_at_ms: u64,
}

/// Key/value store with per-entry expiry. The caller passes the clock in.
#[derive(Default)]
pub struct Store {
    inner: Mutex<HashMap<String, Entry>>,
}

impl Store {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn put(&self, key: &str, value: &str, ttl_ms: u64, now_ms: u64) -> Result<(), StoreError> {
        if key.is_empty() {
            return Err(StoreError::EmptyKey);
        }
        let mut map = self.inner.lock().unwrap();
        map.insert(
            key.to_string(),
            Entry {
                value: value.to_string(),
                expires_at_ms: now_ms.saturating_add(ttl_ms),
            },
        );
        Ok(())
    }

    pub fn get(&self, key: &str, now_ms: u64) -> Option<String> {
        let map = self.inner.lock().unwrap();
        map.get(key)
            .filter(|e| e.expires_at_ms > now_ms)
            .map(|e| e.value.clone())
    }

    /// Number of stored entries, expired ones included until they are purged.
    pub fn len(&self) -> usize {
        self.inner.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_then_get() {
        let s = Store::new();
        s.put("a", "1", 100, 0).unwrap();
        assert_eq!(s.get("a", 50).as_deref(), Some("1"));
    }

    #[test]
    fn entry_expires_at_its_deadline() {
        let s = Store::new();
        s.put("a", "1", 100, 0).unwrap();
        assert_eq!(s.get("a", 99).as_deref(), Some("1"));
        assert_eq!(s.get("a", 100), None);
    }

    #[test]
    fn empty_key_is_rejected() {
        let s = Store::new();
        assert_eq!(s.put("", "1", 100, 0), Err(StoreError::EmptyKey));
        assert!(s.is_empty());
    }
}
