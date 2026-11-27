//! A small in-crate recorder behind the `Telemetry` / `MetricsSource` ports.
//! Exporter wiring (OTLP, a metrics crate) is a later, separate concern: the
//! contract (names, labels, spans) is already honest through the ports.
use std::collections::{BTreeMap, VecDeque};
use std::sync::{Mutex, PoisonError};

use crate::app::{MetricsSource, SpanId, Telemetry};

const KEEP_SPANS: usize = 256;
const MAX_SERIES: usize = 2048;

type Series = (&'static str, String);

#[derive(Default)]
struct Inner {
    counters: BTreeMap<Series, u64>,
    gauges: BTreeMap<Series, i64>,
    open: BTreeMap<u64, OpenSpan>,
    finished: VecDeque<FinishedSpan>,
    next_span: u64,
}

struct OpenSpan {
    name: &'static str,
    attrs: String,
}

/// A completed span, kept in a bounded ring.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FinishedSpan {
    /// Span name.
    pub name: &'static str,
    /// `k="v"` attributes.
    pub attrs: String,
    /// False when the operation failed.
    pub ok: bool,
}

/// The recorder. Series are bounded: past `MAX_SERIES` new series are dropped.
pub struct Recorder {
    log_spans: bool,
    inner: Mutex<Inner>,
}

fn labels_text(labels: &[(&'static str, &str)]) -> String {
    let mut out = String::new();
    for (i, (k, v)) in labels.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(k);
        out.push_str("=\"");
        for c in v.chars() {
            match c {
                '\\' => out.push_str("\\\\"),
                '"' => out.push_str("\\\""),
                '\n' => out.push_str("\\n"),
                c => out.push(c),
            }
        }
        out.push('"');
    }
    out
}

impl Recorder {
    /// `log_spans` writes one line per finished span to stderr.
    pub fn new(log_spans: bool) -> Self {
        Self {
            log_spans,
            inner: Mutex::new(Inner::default()),
        }
    }

    /// The most recent finished spans, oldest first.
    pub fn finished_spans(&self) -> Vec<FinishedSpan> {
        self.lock().finished.iter().cloned().collect()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Telemetry for Recorder {
    fn counter_inc(&self, name: &'static str, labels: &[(&'static str, &str)]) {
        let key = (name, labels_text(labels));
        let mut g = self.lock();
        if g.counters.len() >= MAX_SERIES && !g.counters.contains_key(&key) {
            return;
        }
        let c = g.counters.entry(key).or_insert(0);
        *c = c.saturating_add(1);
    }

    fn gauge_set(&self, name: &'static str, value: i64, labels: &[(&'static str, &str)]) {
        let key = (name, labels_text(labels));
        let mut g = self.lock();
        if g.gauges.len() >= MAX_SERIES && !g.gauges.contains_key(&key) {
            return;
        }
        g.gauges.insert(key, value);
    }

    fn span_start(&self, name: &'static str, attrs: &[(&'static str, &str)]) -> SpanId {
        let mut g = self.lock();
        g.next_span = g.next_span.saturating_add(1);
        let id = g.next_span;
        if g.open.len() < MAX_SERIES {
            g.open.insert(
                id,
                OpenSpan {
                    name,
                    attrs: labels_text(attrs),
                },
            );
        }
        SpanId(id)
    }

    fn span_end(&self, id: SpanId, ok: bool) {
        let mut g = self.lock();
        let Some(open) = g.open.remove(&id.0) else {
            return;
        };
        if self.log_spans {
            eprintln!("span name={} ok={ok} {}", open.name, open.attrs);
        }
        if g.finished.len() >= KEEP_SPANS {
            g.finished.pop_front();
        }
        g.finished.push_back(FinishedSpan {
            name: open.name,
            attrs: open.attrs,
            ok,
        });
    }
}

fn render_family<V: std::fmt::Display>(out: &mut String, kind: &str, series: &BTreeMap<Series, V>) {
    let mut last: Option<&str> = None;
    for ((name, labels), value) in series {
        if last != Some(name) {
            out.push_str(&format!("# TYPE {name} {kind}\n"));
            last = Some(name);
        }
        if labels.is_empty() {
            out.push_str(&format!("{name} {value}\n"));
        } else {
            out.push_str(&format!("{name}{{{labels}}} {value}\n"));
        }
    }
}

impl MetricsSource for Recorder {
    fn render(&self) -> String {
        let g = self.lock();
        let mut out = String::new();
        render_family(&mut out, "counter", &g.counters);
        render_family(&mut out, "gauge", &g.gauges);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counters_gauges_and_spans_are_recorded_and_rendered() {
        let r = Recorder::new(false);
        r.counter_inc("svc_x_total", &[("k", "a\"b")]);
        r.counter_inc("svc_x_total", &[("k", "a\"b")]);
        r.gauge_set("svc_y", -3, &[]);
        let id = r.span_start("svc.op", &[("event_type", "t")]);
        r.span_end(id, false);
        let text = r.render();
        assert!(text.contains("# TYPE svc_x_total counter\n"));
        assert!(text.contains("svc_x_total{k=\"a\\\"b\"} 2\n"));
        assert!(text.contains("svc_y -3\n"));
        assert_eq!(
            r.finished_spans(),
            vec![FinishedSpan {
                name: "svc.op",
                attrs: "event_type=\"t\"".into(),
                ok: false
            }]
        );
    }

    #[test]
    fn the_span_ring_is_bounded() {
        let r = Recorder::new(false);
        for _ in 0..(KEEP_SPANS + 10) {
            let id = r.span_start("svc.op", &[]);
            r.span_end(id, true);
        }
        assert_eq!(r.finished_spans().len(), KEEP_SPANS);
    }
}
