//! Empire cockpit — the desktop side of the fork's leadership dashboard (buzz#15).
//!
//! The webview cannot run `gh`, `ssh` or `jq`, so the numbers are collected by
//! `.empire/tools/cockpit-snapshot.sh` (mirrored into the nest as
//! `cockpit-snapshot.sh`, same pattern as `vault-log.sh`) and dropped as one
//! JSON file in the nest. This module only reads that file and — on explicit
//! user request — re-runs the collector.
//!
//! # The one rule this module exists to enforce
//!
//! **A missing source is a gap, never a zero.** Every failure path returns an
//! envelope whose `snapshot` is `None` and whose `readError` says why, so the
//! UI has nothing it could mistake for "0 open gates". A cockpit that shows an
//! unverified number is worse than no cockpit: on 2026-08-01 a report claimed
//! "no gate open" purely because its data source was missing.
//!
//! Staleness is handled the same way and deliberately in the UI, not here:
//! this module reports `fileModifiedAt` and `readAt` from the same clock and
//! lets the view decide what counts as too old. Hiding an old number behind a
//! fresh-looking tile is the same bug in a slower costume.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;

use crate::managed_agents::nest_dir;

/// File name of the collector output inside the nest.
const SNAPSHOT_FILE: &str = "cockpit.json";
/// File name of the collector itself inside the nest.
const COLLECTOR_FILE: &str = "cockpit-snapshot.sh";
/// Hard ceiling for one collector run. The collector queries GitHub per repo;
/// a hung `gh` must not pin the command forever.
const COLLECTOR_TIMEOUT: Duration = Duration::from_secs(300);
/// Largest snapshot we will parse. The collector writes ~100 KB; anything in
/// megabyte territory is a bug or a foreign file, not a snapshot.
const MAX_SNAPSHOT_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EmpireSnapshotEnvelope {
    /// Absolute path we read (or would have read). Makes "not collected"
    /// actionable instead of mysterious.
    pub path: String,
    /// Parsed collector output. `None` whenever anything went wrong.
    pub snapshot: Option<serde_json::Value>,
    /// Why there is no snapshot. Exactly one of `snapshot` / `read_error` is
    /// `Some` — there is no third state and no empty-but-successful result.
    pub read_error: Option<String>,
    /// Last modification of the snapshot file, RFC 3339.
    pub file_modified_at: Option<String>,
    /// Wall clock when this envelope was built, RFC 3339, same clock as
    /// `file_modified_at` so the UI can subtract them.
    pub read_at: String,
    /// Copy-pasteable command that fills the snapshot.
    pub refresh_hint: String,
    /// Result of the collector run that produced this envelope, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collector: Option<CollectorOutcome>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectorOutcome {
    /// Collector script path we ran.
    pub script: String,
    /// `None` when the process was killed or never started.
    pub exit_code: Option<i32>,
    /// Collector exit codes: 0 = complete, 1 = written with named gaps,
    /// 2 = nothing written (previous snapshot left untouched).
    pub wrote_snapshot: bool,
    /// Tail of stderr — the collector reports its gaps there.
    pub message: String,
}

fn refresh_hint(script: &Path) -> String {
    format!("bash \"{}\"", script.display())
}

fn snapshot_path() -> Result<PathBuf, String> {
    Ok(nest_dir()
        .ok_or_else(|| "Buzz-Nest (~/.buzz) nicht auflösbar — $HOME fehlt".to_string())?
        .join(SNAPSHOT_FILE))
}

fn collector_path() -> Result<PathBuf, String> {
    Ok(nest_dir()
        .ok_or_else(|| "Buzz-Nest (~/.buzz) nicht auflösbar — $HOME fehlt".to_string())?
        .join(COLLECTOR_FILE))
}

fn rfc3339(time: std::time::SystemTime) -> String {
    chrono::DateTime::<chrono::Utc>::from(time).to_rfc3339()
}

/// Reads and parses the snapshot file.
///
/// Split out from the command so the failure classification is a pure function
/// of a path and can be exercised by tests without a Tauri app handle.
fn load_snapshot(path: &Path) -> (Option<serde_json::Value>, Option<String>, Option<String>) {
    let meta = match std::fs::metadata(path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return (
                None,
                Some(format!(
                    "kein Snapshot vorhanden ({}) — der Sammler lief hier noch nie",
                    path.display()
                )),
                None,
            );
        }
        Err(error) => {
            return (None, Some(format!("Snapshot nicht lesbar: {error}")), None);
        }
    };

    if !meta.is_file() {
        return (
            None,
            Some(format!("{} ist keine Datei", path.display())),
            None,
        );
    }

    let modified = meta.modified().ok().map(rfc3339);

    if meta.len() == 0 {
        return (
            None,
            Some("Snapshot ist leer — der Sammler ist mitten im Schreiben abgebrochen".to_string()),
            modified,
        );
    }
    if meta.len() > MAX_SNAPSHOT_BYTES {
        return (
            None,
            Some(format!(
                "Snapshot ist {} Bytes groß (Grenze {MAX_SNAPSHOT_BYTES}) — wird nicht geparst",
                meta.len()
            )),
            modified,
        );
    }

    let raw = match std::fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(error) => {
            return (
                None,
                Some(format!("Snapshot nicht lesbar: {error}")),
                modified,
            );
        }
    };

    match serde_json::from_str::<serde_json::Value>(&raw) {
        Ok(value) if value.is_object() => (Some(value), None, modified),
        Ok(_) => (
            None,
            Some("Snapshot ist kein JSON-Objekt — Datei stammt nicht vom Sammler".to_string()),
            modified,
        ),
        Err(error) => (
            None,
            Some(format!("Snapshot ist kein gültiges JSON: {error}")),
            modified,
        ),
    }
}

fn envelope_for(path: &Path, collector: Option<CollectorOutcome>) -> EmpireSnapshotEnvelope {
    let (snapshot, read_error, file_modified_at) = load_snapshot(path);
    let script = path.with_file_name(COLLECTOR_FILE);
    EmpireSnapshotEnvelope {
        path: path.display().to_string(),
        snapshot,
        read_error,
        file_modified_at,
        read_at: crate::util::now_iso(),
        refresh_hint: refresh_hint(&script),
        collector,
    }
}

/// Reads the current cockpit snapshot. Never fails for "no data" — that is a
/// populated `readError`, which is what the UI must render as a gap.
#[tauri::command]
pub async fn read_empire_snapshot() -> Result<EmpireSnapshotEnvelope, String> {
    let path = snapshot_path()?;
    tokio::task::spawn_blocking(move || envelope_for(&path, None))
        .await
        .map_err(|error| format!("spawn_blocking failed: {error}"))
}

/// Re-runs the collector, then re-reads the snapshot.
///
/// The script path is fixed (`<nest>/cockpit-snapshot.sh`) and takes no
/// arguments from the UI — the button cannot become a shell.
#[tauri::command]
pub async fn refresh_empire_snapshot() -> Result<EmpireSnapshotEnvelope, String> {
    let path = snapshot_path()?;
    let script = collector_path()?;

    tokio::task::spawn_blocking(move || {
        let outcome = run_collector(&script);
        envelope_for(&path, Some(outcome))
    })
    .await
    .map_err(|error| format!("spawn_blocking failed: {error}"))
}

fn bash_command() -> std::process::Command {
    #[cfg(windows)]
    {
        if let Some(bash) = crate::managed_agents::git_bash::resolve_bash_path() {
            return std::process::Command::new(bash);
        }
    }
    std::process::Command::new("bash")
}

fn tail(text: &str, max: usize) -> String {
    let trimmed = text.trim();
    if trimmed.chars().count() <= max {
        return trimmed.to_string();
    }
    let skip = trimmed.chars().count() - max;
    format!("…{}", trimmed.chars().skip(skip).collect::<String>())
}

fn run_collector(script: &Path) -> CollectorOutcome {
    let script_display = script.display().to_string();

    if !script.is_file() {
        return CollectorOutcome {
            script: script_display.clone(),
            exit_code: None,
            wrote_snapshot: false,
            message: format!(
                "Sammler nicht gefunden. Einmalig aus dem Repo spiegeln: cp .empire/tools/{COLLECTOR_FILE} {script_display}"
            ),
        };
    }

    let mut command = bash_command();
    command
        .arg(script)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW — the collector must not flash a console window.
        command.creation_flags(0x0800_0000);
    }

    let child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            return CollectorOutcome {
                script: script_display,
                exit_code: None,
                wrote_snapshot: false,
                message: format!("Sammler nicht startbar (bash fehlt?): {error}"),
            };
        }
    };

    match wait_with_timeout(child, COLLECTOR_TIMEOUT) {
        Ok(output) => {
            let code = output.status.code();
            let stderr = String::from_utf8_lossy(&output.stderr);
            // 0 = complete, 1 = written but with named gaps. Everything else
            // means the collector deliberately left the previous file alone.
            let wrote_snapshot = matches!(code, Some(0) | Some(1));
            CollectorOutcome {
                script: script_display,
                exit_code: code,
                wrote_snapshot,
                message: tail(&stderr, 600),
            }
        }
        Err(message) => CollectorOutcome {
            script: script_display,
            exit_code: None,
            wrote_snapshot: false,
            message,
        },
    }
}

fn wait_with_timeout(
    mut child: std::process::Child,
    timeout: Duration,
) -> Result<std::process::Output, String> {
    let started = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => {
                return child
                    .wait_with_output()
                    .map_err(|error| format!("Sammler-Ausgabe nicht lesbar: {error}"));
            }
            Ok(None) => {}
            Err(error) => return Err(format!("Sammler-Status nicht lesbar: {error}")),
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!(
                "Sammler nach {}s abgebrochen — voriger Snapshot bleibt unverändert",
                timeout.as_secs()
            ));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "buzz-cockpit-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    #[test]
    fn missing_file_is_a_named_gap_not_an_empty_snapshot() {
        let dir = temp_dir("missing");
        let path = dir.join("cockpit.json");
        let _ = std::fs::remove_file(&path);

        let (snapshot, error, modified) = load_snapshot(&path);

        assert!(snapshot.is_none(), "missing file must not yield a snapshot");
        assert!(modified.is_none());
        let error = error.expect("missing file must produce a reason");
        assert!(
            error.contains("kein Snapshot vorhanden"),
            "reason must name the gap, got: {error}"
        );
    }

    #[test]
    fn invalid_json_is_a_gap() {
        let dir = temp_dir("invalid");
        let path = dir.join("cockpit.json");
        std::fs::write(&path, "{ this is not json").unwrap();

        let (snapshot, error, _) = load_snapshot(&path);

        assert!(snapshot.is_none());
        assert!(error.unwrap().contains("kein gültiges JSON"));
    }

    #[test]
    fn truncated_empty_file_is_a_gap() {
        let dir = temp_dir("empty");
        let path = dir.join("cockpit.json");
        std::fs::write(&path, "").unwrap();

        let (snapshot, error, _) = load_snapshot(&path);

        assert!(snapshot.is_none());
        assert!(error.unwrap().contains("leer"));
    }

    #[test]
    fn json_array_is_rejected() {
        let dir = temp_dir("array");
        let path = dir.join("cockpit.json");
        std::fs::write(&path, "[1,2,3]").unwrap();

        let (snapshot, error, _) = load_snapshot(&path);

        assert!(snapshot.is_none());
        assert!(error.unwrap().contains("kein JSON-Objekt"));
    }

    #[test]
    fn valid_snapshot_parses_and_carries_mtime() {
        let dir = temp_dir("valid");
        let path = dir.join("cockpit.json");
        std::fs::write(
            &path,
            r#"{"schema_version":1,"backlog":{"state":"ok","ready_total":7}}"#,
        )
        .unwrap();

        let (snapshot, error, modified) = load_snapshot(&path);

        assert!(error.is_none(), "valid snapshot must not report an error");
        let snapshot = snapshot.expect("valid snapshot must parse");
        assert_eq!(snapshot["backlog"]["ready_total"], 7);
        assert!(modified.is_some(), "mtime is what makes staleness visible");
    }

    #[test]
    fn envelope_always_names_a_refresh_command() {
        let dir = temp_dir("hint");
        let path = dir.join("cockpit.json");
        let _ = std::fs::remove_file(&path);

        let envelope = envelope_for(&path, None);

        assert!(envelope.snapshot.is_none());
        assert!(envelope.read_error.is_some());
        assert!(envelope.refresh_hint.contains(COLLECTOR_FILE));
    }

    #[test]
    fn missing_collector_reports_how_to_install_it() {
        let dir = temp_dir("nocollector");
        let script = dir.join("does-not-exist.sh");

        let outcome = run_collector(&script);

        assert!(!outcome.wrote_snapshot);
        assert!(outcome.exit_code.is_none());
        assert!(outcome.message.contains("cp .empire/tools/"));
    }

    #[test]
    fn tail_keeps_the_end_of_long_output() {
        assert_eq!(tail("  short  ", 20), "short");
        let long: String = std::iter::repeat_n('x', 50).collect();
        let cut = tail(&long, 10);
        assert_eq!(cut.chars().count(), 11, "10 chars plus the ellipsis");
        assert!(cut.starts_with('…'));
    }
}
