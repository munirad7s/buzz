use super::snapshot::{compose_snapshot, SnapshotSource, MAX_SNAPSHOT_BYTES};

#[test]
fn missing_sources_are_named_gaps_not_zeroes() {
    let snapshot = compose_snapshot(
        SnapshotSource::Gap("cockpit snapshot missing".to_string()),
        SnapshotSource::Gap("relay unavailable".to_string()),
    );
    assert!(snapshot.content.contains("GAPS"));
    assert!(snapshot.content.contains("cockpit snapshot missing"));
    assert!(snapshot.content.contains("relay unavailable"));
    assert_eq!(snapshot.gaps.len(), 2);
    assert!(!snapshot.content.contains("0 open"));
}

#[test]
fn partial_snapshot_retains_available_context() {
    let snapshot = compose_snapshot(
        SnapshotSource::Available("ready_total: 7".to_string()),
        SnapshotSource::Gap("relay unavailable".to_string()),
    );
    assert!(snapshot.content.contains("ready_total: 7"));
    assert_eq!(snapshot.gaps, vec!["relay unavailable"]);
}

#[test]
fn snapshot_is_valid_utf8_and_never_exceeds_16_kib() {
    let long = "🟠".repeat(MAX_SNAPSHOT_BYTES);
    let snapshot = compose_snapshot(
        SnapshotSource::Available(long),
        SnapshotSource::Available("relay ok".to_string()),
    );
    assert!(snapshot.content.len() <= MAX_SNAPSHOT_BYTES);
    assert!(snapshot.truncated);
    assert!(std::str::from_utf8(snapshot.content.as_bytes()).is_ok());
}
