use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VoiceErrorCode {
    NotLoggedIn,
    Entitlement,
    Quota,
    AppServer,
    Protocol,
    Timeout,
    InvalidRequest,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VoiceCommandError {
    pub code: VoiceErrorCode,
    pub message: String,
}

impl VoiceCommandError {
    pub fn protocol() -> Self {
        Self {
            code: VoiceErrorCode::Protocol,
            message: "Codex App-Server hat eine ungueltige Antwort geliefert.".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ServerMessage {
    ServerRequest {
        id: u64,
        method: String,
    },
    Response {
        id: u64,
        result: Value,
    },
    ErrorResponse {
        id: u64,
        code: VoiceErrorCode,
        message: String,
    },
    RealtimeSdp {
        thread_id: String,
        sdp: String,
    },
    RealtimeError {
        thread_id: Option<String>,
        code: VoiceErrorCode,
        message: String,
    },
    Notification,
}

fn text_at<'a>(value: &'a Value, path: &[&str]) -> Option<&'a str> {
    path.iter()
        .try_fold(value, |current, segment| current.get(segment))?
        .as_str()
}

fn classify_error(value: &Value) -> (VoiceErrorCode, String) {
    let numeric_code = value.get("code").and_then(Value::as_i64);
    let raw = value
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();

    if numeric_code == Some(403) || raw.contains("entitlement") || raw.contains("not entitled") {
        return (
            VoiceErrorCode::Entitlement,
            "Realtime ist fuer dieses ChatGPT-Konto nicht freigeschaltet.".to_string(),
        );
    }
    if raw.contains("quota") || raw.contains("rate limit") || raw.contains("usage limit") {
        return (
            VoiceErrorCode::Quota,
            "Realtime-Kontingent ist derzeit nicht verfuegbar.".to_string(),
        );
    }
    if raw.contains("login") || raw.contains("not authenticated") || raw.contains("chatgpt") {
        return (
            VoiceErrorCode::NotLoggedIn,
            "Codex ist nicht mit ChatGPT angemeldet.".to_string(),
        );
    }

    (
        VoiceErrorCode::AppServer,
        "Codex App-Server konnte die Voice-Session nicht starten.".to_string(),
    )
}

pub fn classify_server_message(value: Value) -> Result<ServerMessage, VoiceCommandError> {
    if let Some(id) = value.get("id").and_then(Value::as_u64) {
        if let Some(method) = value.get("method").and_then(Value::as_str) {
            return Ok(ServerMessage::ServerRequest {
                id,
                method: method.to_string(),
            });
        }
        if let Some(error) = value.get("error") {
            let (code, message) = classify_error(error);
            return Ok(ServerMessage::ErrorResponse { id, code, message });
        }
        if let Some(result) = value.get("result") {
            return Ok(ServerMessage::Response {
                id,
                result: result.clone(),
            });
        }
        return Err(VoiceCommandError::protocol());
    }

    match value.get("method").and_then(Value::as_str) {
        Some("thread/realtime/sdp") => {
            let thread_id =
                text_at(&value, &["params", "threadId"]).ok_or_else(VoiceCommandError::protocol)?;
            let sdp =
                text_at(&value, &["params", "sdp"]).ok_or_else(VoiceCommandError::protocol)?;
            Ok(ServerMessage::RealtimeSdp {
                thread_id: thread_id.to_string(),
                sdp: sdp.to_string(),
            })
        }
        Some("thread/realtime/error") => {
            let error = value
                .get("params")
                .and_then(|params| params.get("error"))
                .ok_or_else(VoiceCommandError::protocol)?;
            let (code, message) = classify_error(error);
            Ok(ServerMessage::RealtimeError {
                thread_id: text_at(&value, &["params", "threadId"]).map(str::to_string),
                code,
                message,
            })
        }
        Some(_) => Ok(ServerMessage::Notification),
        None => Err(VoiceCommandError::protocol()),
    }
}
