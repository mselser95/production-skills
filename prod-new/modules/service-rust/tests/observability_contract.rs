//! Observability contract: the manifests and the code agree in both
//! directions. Code side = literal first arguments of `counter_inc(`,
//! `gauge_set(` and `span_start(` in `src/` (non-test code). A call whose name
//! is not a literal is itself a failure, because the scan could not see it.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

/// Names (and, for metrics, types) declared as `- name: x` entries.
fn manifest(file: &str) -> Vec<(String, String)> {
    let text = fs::read_to_string(root().join("observability").join(file)).unwrap();
    let mut out: Vec<(String, String)> = Vec::new();
    for line in text.lines() {
        if let Some(n) = line.strip_prefix("- name:") {
            out.push((n.trim().to_owned(), String::new()));
        } else if let Some(t) = line.trim().strip_prefix("type:") {
            if let Some(last) = out.last_mut() {
                last.1 = t.trim().to_owned();
            }
        }
    }
    out
}

/// Literal names passed to `call(`; the second value counts every call site.
fn emitted(call: &str) -> (BTreeSet<String>, usize, usize) {
    let mut files = Vec::new();
    rust_files(&root().join("src"), &mut files);
    let needle = format!("{call}(");
    let (mut names, mut sites, mut literal) = (BTreeSet::new(), 0, 0);
    for f in files {
        let text = fs::read_to_string(&f).unwrap();
        let code = text.split("#[cfg(test)]").next().unwrap_or("");
        let code: String = code
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join("\n");
        let mut rest = code.as_str();
        while let Some(i) = rest.find(&needle) {
            let before = &rest[..i];
            let after = &rest[i + needle.len()..];
            rest = after;
            if before.trim_end().ends_with("fn") {
                continue; // the trait method's own declaration
            }
            sites += 1;
            // rustfmt may move the argument onto the next line
            if let Some(lit) = after.trim_start().strip_prefix('"') {
                if let Some(end) = lit.find('"') {
                    literal += 1;
                    names.insert(lit[..end].to_owned());
                }
            }
        }
    }
    (names, sites, literal)
}

fn metrics_in_code() -> (BTreeSet<String>, BTreeSet<String>) {
    let (c, cs, cl) = emitted("counter_inc");
    let (g, gs, gl) = emitted("gauge_set");
    assert_eq!(cs, cl, "a counter_inc call has a non-literal name");
    assert_eq!(gs, gl, "a gauge_set call has a non-literal name");
    (c, g)
}

fn set(v: impl Iterator<Item = String>) -> BTreeSet<String> {
    v.collect()
}

#[test]
fn counters_match_the_manifest_both_ways() {
    let (code, _) = metrics_in_code();
    let m = manifest("emitted-metrics.yaml");
    let declared = set(m
        .iter()
        .filter(|(_, t)| t == "counter")
        .map(|(n, _)| n.clone()));
    let undeclared: Vec<_> = code.difference(&declared).collect();
    let dead: Vec<_> = declared.difference(&code).collect();
    assert!(
        undeclared.is_empty(),
        "emitted but not in emitted-metrics.yaml: {undeclared:?}"
    );
    assert!(
        dead.is_empty(),
        "in emitted-metrics.yaml but never emitted: {dead:?}"
    );
}

#[test]
fn gauges_match_the_manifest_both_ways() {
    let (_, code) = metrics_in_code();
    let m = manifest("emitted-metrics.yaml");
    let declared = set(m
        .iter()
        .filter(|(_, t)| t == "gauge")
        .map(|(n, _)| n.clone()));
    let undeclared: Vec<_> = code.difference(&declared).collect();
    let dead: Vec<_> = declared.difference(&code).collect();
    assert!(
        undeclared.is_empty(),
        "emitted but not in emitted-metrics.yaml: {undeclared:?}"
    );
    assert!(
        dead.is_empty(),
        "in emitted-metrics.yaml but never emitted: {dead:?}"
    );
}

#[test]
fn spans_match_the_manifest_both_ways() {
    let (code, sites, literal) = emitted("span_start");
    assert_eq!(sites, literal, "a span_start call has a non-literal name");
    let declared = set(manifest("spans.yaml").into_iter().map(|(n, _)| n));
    let undeclared: Vec<_> = code.difference(&declared).collect();
    let dead: Vec<_> = declared.difference(&code).collect();
    assert!(
        undeclared.is_empty(),
        "span emitted but not in spans.yaml: {undeclared:?}"
    );
    assert!(
        dead.is_empty(),
        "span in spans.yaml but never started: {dead:?}"
    );
}

#[test]
fn manifest_entries_follow_the_naming_rules() {
    let metrics = manifest("emitted-metrics.yaml");
    assert!(!metrics.is_empty());
    let mut seen = BTreeSet::new();
    for (name, kind) in &metrics {
        assert!(seen.insert(name.clone()), "duplicate metric {name}");
        assert!(name.starts_with("svc_"), "{name}: want the svc_ prefix");
        assert!(
            kind == "counter" || kind == "gauge",
            "{name}: type {kind:?}"
        );
        assert_eq!(
            name.ends_with("_total"),
            kind == "counter",
            "{name}: _total iff counter"
        );
    }
    for (name, _) in manifest("spans.yaml") {
        assert!(name.starts_with("svc."), "{name}: want the svc. prefix");
    }
}
