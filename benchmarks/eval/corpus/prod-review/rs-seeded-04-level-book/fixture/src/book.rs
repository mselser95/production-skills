use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Bid,
    Ask,
}

/// Set the quantity resting at `price`; a quantity of zero removes the level.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Update {
    pub side: Side,
    pub price: u64,
    pub qty: u64,
}

/// Prices and quantities are integers in the instrument's smallest unit.
#[derive(Debug, Clone, Default)]
pub struct OrderBook {
    bids: BTreeMap<u64, u64>,
    asks: BTreeMap<u64, u64>,
}

impl OrderBook {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn apply(&mut self, u: &Update) {
        let side = match u.side {
            Side::Bid => &mut self.bids,
            Side::Ask => &mut self.asks,
        };
        if u.qty == 0 {
            side.remove(&u.price);
        } else {
            side.insert(u.price, u.qty);
        }
    }

    /// Highest bid as `(price, qty)`.
    pub fn best_bid(&self) -> Option<(u64, u64)> {
        self.bids.iter().next_back().map(|(p, q)| (*p, *q))
    }

    /// Lowest ask as `(price, qty)`.
    pub fn best_ask(&self) -> Option<(u64, u64)> {
        self.asks.iter().next().map(|(p, q)| (*p, *q))
    }

    /// Up to `n` bid levels, best (highest) first.
    pub fn top_bids(&self, n: usize) -> Vec<(u64, u64)> {
        self.bids
            .iter()
            .rev()
            .take(n)
            .map(|(p, q)| (*p, *q))
            .collect()
    }

    /// Up to `n` ask levels, best (lowest) first.
    pub fn top_asks(&self, n: usize) -> Vec<(u64, u64)> {
        self.asks.iter().take(n).map(|(p, q)| (*p, *q)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn upd(side: Side, price: u64, qty: u64) -> Update {
        Update { side, price, qty }
    }

    #[test]
    fn best_levels_follow_updates() {
        let mut b = OrderBook::new();
        b.apply(&upd(Side::Bid, 100, 5));
        b.apply(&upd(Side::Bid, 101, 2));
        b.apply(&upd(Side::Ask, 103, 7));
        assert_eq!(b.best_bid(), Some((101, 2)));
        assert_eq!(b.best_ask(), Some((103, 7)));
    }

    #[test]
    fn zero_quantity_removes_the_level() {
        let mut b = OrderBook::new();
        b.apply(&upd(Side::Bid, 100, 5));
        b.apply(&upd(Side::Bid, 100, 0));
        assert_eq!(b.best_bid(), None);
    }

    #[test]
    fn top_levels_are_ordered_best_first() {
        let mut b = OrderBook::new();
        for (p, q) in [(100, 1), (102, 2), (101, 3)] {
            b.apply(&upd(Side::Bid, p, q));
            b.apply(&upd(Side::Ask, p + 10, q));
        }
        assert_eq!(b.top_bids(2), vec![(102, 2), (101, 3)]);
        assert_eq!(b.top_asks(2), vec![(110, 1), (111, 3)]);
    }
}
