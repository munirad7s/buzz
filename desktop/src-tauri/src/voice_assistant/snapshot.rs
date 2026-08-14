use serde::Serialize;

use crate::{app_state::AppState, relay::query_relay};

pub const MAX_SNAPSHOT_BYTES: usize = 16 * 1024;

pub enum SnapshotSource {
    Available(String),
    Gap(String),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceSnapshot {
    pub generated_at: String,
    pub content: String,
    pub truncated: bool,
    pub gaps: Vec<String>,
}

fn truncate_utf8(mut value: String, max_bytes: usize) -> (String, bool) {
    if value.len() <= max_bytes {
        return (value, false);
    }
    let mut boundary = max_bytes;
    while !value.is_char_boundary(boundary) {
        boundary -= 1;
    }
    value.truncate(boundary);
    (value, true)
}

pub fn compose_snapshot(cockpit: SnapshotSource, relay: SnapshotSource) -> VoiceSnapshot {
    let mut sections = Vec::new();
    let mut gaps = Vec::new();
    for (name, source) in [("COCKPIT", cockpit), ("RELAY FEED", relay)] {
        match source {
            SnapshotSource::Available(content) => {
                sections.push(format!("{name}\n{}", content.trim()));
            }
            SnapshotSource::Gap(reason) => gaps.push(reason),
        }
    }
    if !gaps.is_empty() {
        sections.push(format!(
            "GAPS (unknown, never zero)\n- {}",
            gaps.join("\n- ")
        ));
    }
    let (content, truncated) = truncate_utf8(sections.join("\n\n"), MAX_SNAPSHOT_BYTES);
    VoiceSnapshot {
        generated_at: crate::util::now_iso(),
        content,
        truncated,
        gaps,
    }
}

fn cockpit_source() -> SnapshotSource {
    match crate::commands::load_empire_snapshot_for_voice() {
        Ok(value) => SnapshotSource::Available(
            serde_json::to_string_pretty(&value)
                .unwrap_or_else(|_| "cockpit serialization unavailable".to_string()),
        ),
        Err(reason) => SnapshotSource::Gap(format!("Cockpit: {reason}")),
    }
}

async fn relay_source(state: &AppState) -> SnapshotSource {
    let filter = serde_json::json!({
        "kinds": [1, 9, 45001, 45003],
        "limit": 20
    });
    match query_relay(state, &[filter]).await {
        Ok(events) => {
            let excerpt = events
                .into_iter()
                .rev()
                .filter_map(|event| {
                    let content = event.content.trim();
                    if content.is_empty() {
                        None
                    } else {
                        Some(format!(
                            "- {} | kind {} | {}",
                            event.created_at.to_human_datetime(),
                            event.kind.as_u16(),
                            content.chars().take(600).collect::<String>()
                        ))
                    }
                })
                .collect::<Vec<_>>();
            if excerpt.is_empty() {
                SnapshotSource::Gap("Relay feed: no verified recent events".to_string())
            } else {
                SnapshotSource::Available(excerpt.join("\n"))
            }
        }
        Err(_) => SnapshotSource::Gap("Relay feed: authenticated query unavailable".to_string()),
    }
}

pub async fn build_voice_snapshot(state: &AppState) -> VoiceSnapshot {
    compose_snapshot(cockpit_source(), relay_source(state).await)
}
