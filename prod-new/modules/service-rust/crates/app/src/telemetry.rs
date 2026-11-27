//! The ONE declaration of every metric and span this service can emit.
//!
//! `Telemetry` takes these enums, never a string, so a name that is not
//! declared here does not compile. Each enum, its `ALL` list and its `spec`
//! come from one macro invocation, so they cannot drift apart. The
//! observability contract test compares [`table`] with
//! `observability/*.yaml` in both directions: name, type and label keys.
use alloc::vec::Vec;

/// Name and closed label-key set of one signal.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Spec {
    /// The series or span name, exactly as exported.
    pub name: &'static str,
    /// Label (or attribute) keys, in the order values are passed.
    pub labels: &'static [&'static str],
}

macro_rules! signals {
    ($(#[$m:meta])* $enum:ident { $($var:ident => ($name:literal, [$($label:literal),*])),+ $(,)? }) => {
        $(#[$m])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub enum $enum { $(
            #[doc = $name]
            $var
        ),+ }

        impl $enum {
            /// Every variant.
            pub const ALL: &'static [$enum] = &[$($enum::$var),+];

            /// Name and label keys.
            pub const fn spec(self) -> Spec {
                match self {
                    $($enum::$var => Spec { name: $name, labels: &[$($label),*] }),+
                }
            }
        }
    };
}

signals! {
    /// Monotonic counters.
    Counter {
        UnitsConservedViolations => ("svc_units_conserved_violations_total", []),
        Events => ("svc_events_total", ["kind", "outcome"]),
        HttpRequests => ("svc_http_requests_total", ["route", "code"]),
    }
}

signals! {
    /// Gauges.
    Gauge {
        BuildInfo => ("svc_build_info", ["revision", "config_digest"]),
        BalanceUnits => ("svc_balance_units", []),
        LastAppliedUnixSeconds => ("svc_last_applied_unix_seconds", []),
    }
}

signals! {
    /// Spans.
    SpanName {
        Deposit => ("svc.deposit", ["event_type"]),
        Withdraw => ("svc.withdraw", ["event_type"]),
    }
}

/// One row of [`table`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    /// `counter`, `gauge` or `span`.
    pub kind: &'static str,
    /// Name.
    pub name: &'static str,
    /// Label keys.
    pub labels: Vec<&'static str>,
}

/// Every declared signal with its type and label keys.
pub fn table() -> Vec<Row> {
    let mut rows = Vec::new();
    let mut push = |kind: &'static str, s: Spec| {
        rows.push(Row {
            kind,
            name: s.name,
            labels: s.labels.to_vec(),
        });
    };
    Counter::ALL.iter().for_each(|c| push("counter", c.spec()));
    Gauge::ALL.iter().for_each(|g| push("gauge", g.spec()));
    SpanName::ALL.iter().for_each(|s| push("span", s.spec()));
    rows
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_lists_every_variant_once() {
        let rows = table();
        assert_eq!(
            rows.len(),
            Counter::ALL.len() + Gauge::ALL.len() + SpanName::ALL.len()
        );
        let mut names: Vec<&str> = rows.iter().map(|r| r.name).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), rows.len());
    }
}
