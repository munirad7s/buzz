use tauri::State;
use tokio::sync::Mutex;

use crate::app_state::AppState;

use super::client::{VoiceClient, VoiceStartResponse};
use super::protocol::VoiceCommandError;
use super::snapshot::{build_voice_snapshot, VoiceSnapshot};

#[derive(Default)]
pub struct VoiceAssistantState {
    client: Mutex<VoiceClient>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceSessionResponse {
    pub thread_id: String,
    pub sdp_answer: String,
    pub snapshot: VoiceSnapshot,
}

#[tauri::command]
pub async fn voice_start(
    app_state: State<'_, AppState>,
    voice: State<'_, VoiceAssistantState>,
    sdp: String,
) -> Result<VoiceSessionResponse, VoiceCommandError> {
    let snapshot = build_voice_snapshot(&app_state).await;
    let VoiceStartResponse {
        thread_id,
        sdp_answer,
    } = voice
        .client
        .lock()
        .await
        .start(&sdp, &snapshot.content)
        .await?;
    Ok(VoiceSessionResponse {
        thread_id,
        sdp_answer,
        snapshot,
    })
}

#[tauri::command]
pub async fn voice_stop(
    voice: State<'_, VoiceAssistantState>,
    thread_id: String,
) -> Result<(), VoiceCommandError> {
    voice.client.lock().await.stop(&thread_id).await
}
