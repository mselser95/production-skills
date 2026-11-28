//! Observability contract: the typed table in `svc_app::telemetry` (the only
//! way to name a metric or span; a string does not compile) and the manifests
//! in `observability/` agree in both directions: name, type and label keys.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use svc_app::telemetry::{table, Row};

type Entry = (String, Vec<String>); // (kind, label keys) by name

fn code_side(rows: Vec<Row>) -> BTreeMap<String, Entry> {
    rows.into_iter()
        .map(|r| {
            (
                r.name.to_owned(),
                (
                    r.kind.to_owned(),
                    r.labels.iter().map(|l| (*l).to_owned()).collect(),
                ),
            )
        })
        .collect()
}

fn list(value: &str) -> Vec<String> {
    value
        .trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .split(',')
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Reads `- name:` entries with `type:` (metrics) and `labels:` / `attrs:`.
fn parse_manifest(text: &str, default_kind: Option<&str>) -> BTreeMap<String, Entry> {
    let mut out: BTreeMap<String, Entry> = BTreeMap::new();
    let mut current: Option<String> = None;
    for line in text.lines() {
        if let Some(n) = line.strip_prefix("- name:") {
            let name = n.trim().to_owned();
            let kind = default_kind.unwrap_or("").to_owned();
            assert!(
                out.insert(name.clone(), (kind, Vec::new())).is_none(),
                "{name} listed twice"
            );
            current = Some(name);
        } else if let Some(name) = &current {
            let t = line.trim();
            if let Some(v) = t.strip_prefix("type:") {
                out.get_mut(name).unwrap().0 = v.trim().to_owned();
            } else if let Some(v) = t
                .strip_prefix("labels:")
                .or_else(|| t.strip_prefix("attrs:"))
            {
                out.get_mut(name).unwrap().1 = list(v);
            }
        }
    }
    out
}

fn manifests() -> BTreeMap<String, Entry> {
    let dir = std::env::var_os("CARGO_MANIFEST_DIR")
        .map_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")), PathBuf::from)
        .join("observability");
    let metrics = fs::read_to_string(dir.join("emitted-metrics.yaml")).unwrap();
    let spans = fs::read_to_string(dir.join("spans.yaml")).unwrap();
    let mut all = parse_manifest(&metrics, None);
    for (k, v) in parse_manifest(&spans, Some("span")) {
        assert!(all.insert(k.clone(), v).is_none(), "{k} in both manifests");
    }
    all
}

/// Every disagreement, in both directions.
fn diff(code: &BTreeMap<String, Entry>, manifest: &BTreeMap<String, Entry>) -> Vec<String> {
    let mut out = Vec::new();
    for (name, c) in code {
        match manifest.get(name) {
            None => out.push(format!("{name}: in code, not in the manifest")),
            Some(m) if m.0 != c.0 => {
                out.push(format!("{name}: type code={} manifest={}", c.0, m.0));
            }
            Some(m) if m.1 != c.1 => {
                out.push(format!("{name}: labels code={:?} manifest={:?}", c.1, m.1));
            }
            Some(_) => {}
        }
    }
    for name in manifest.keys().filter(|n| !code.contains_key(*n)) {
        out.push(format!("{name}: in the manifest, no variant emits it"));
    }
    out
}

#[test]
fn the_typed_table_matches_the_manifests_both_ways() {
    let problems = diff(&code_side(table()), &manifests());
    assert!(problems.is_empty(), "{problems:#?}");
}

fn sample() -> BTreeMap<String, Entry> {
    let mut m = BTreeMap::new();
    m.insert(
        "svc_a_total".to_owned(),
        ("counter".to_owned(), vec!["k".to_owned()]),
    );
    m.insert("svc_b".to_owned(), ("gauge".to_owned(), Vec::new()));
    m
}

#[test]
fn the_comparison_catches_each_kind_of_drift() {
    let base = sample();
    assert!(diff(&base, &base).is_empty());

    let mut manifest = base.clone();
    manifest.remove("svc_b");
    assert_eq!(
        diff(&base, &manifest).len(),
        1,
        "variant without a manifest entry"
    );

    let mut code = base.clone();
    code.remove("svc_b");
    assert_eq!(
        diff(&code, &base).len(),
        1,
        "manifest entry without a variant"
    );

    let mut manifest = base.clone();
    manifest.get_mut("svc_a_total").unwrap().1 = vec!["other".to_owned()];
    assert_eq!(diff(&base, &manifest).len(), 1, "label key changed");

    let mut manifest = base.clone();
    manifest.get_mut("svc_b").unwrap().0 = "counter".to_owned();
    assert_eq!(diff(&base, &manifest).len(), 1, "type changed");
}

#[test]
fn naming_conventions_hold() {
    for (name, (kind, _)) in manifests() {
        match kind.as_str() {
            "counter" => assert!(
                name.starts_with("svc_") && name.ends_with("_total"),
                "{name}"
            ),
            "gauge" => assert!(name.starts_with("svc_"), "{name}"),
            "span" => assert!(name.starts_with("svc."), "{name}"),
            other => panic!("{name}: unknown type {other:?}"),
        }
    }
}
