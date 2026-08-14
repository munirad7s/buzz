use serde_json::json;

use super::protocol::{classify_server_message, ServerMessage, VoiceErrorCode};

#[test]
fn server_request_is_distinct_from_a_response() {
    assert_eq!(
        classify_server_message(json!({
            "id": 2,
            "method": "item/tool/requestUserInput",
            "params": {"questions": []}
        }))
        .unwrap(),
        ServerMessage::ServerRequest {
            id: 2,
            method: "item/tool/requestUserInput".to_string()
        }
    );
}

#[test]
fn start_ack_is_not_an_sdp_answer() {
    assert_eq!(
        classify_server_message(json!({"id": 3, "result": {}})).unwrap(),
        ServerMessage::Response {
            id: 3,
            result: json!({})
        }
    );
}

#[test]
fn matching_sdp_notification_is_success_data() {
    assert_eq!(
        classify_server_message(json!({
            "method": "thread/realtime/sdp",
            "params": {"threadId": "thread-1", "sdp": "answer-sdp"}
        }))
        .unwrap(),
        ServerMessage::RealtimeSdp {
            thread_id: "thread-1".to_string(),
            sdp: "answer-sdp".to_string()
        }
    );
}

#[test]
fn realtime_error_is_sanitized_and_classified() {
    assert_eq!(
        classify_server_message(json!({
            "method": "thread/realtime/error",
            "params": {
                "threadId": "thread-1",
                "error": {"code": 403, "message": "Bearer secret-token is not entitled"}
            }
        }))
        .unwrap(),
        ServerMessage::RealtimeError {
            thread_id: Some("thread-1".to_string()),
            code: VoiceErrorCode::Entitlement,
            message: "Realtime ist fuer dieses ChatGPT-Konto nicht freigeschaltet.".to_string()
        }
    );
}

#[test]
fn quota_error_has_a_distinct_stable_code() {
    assert_eq!(
        classify_server_message(json!({
            "id": 7,
            "error": {"code": -32000, "message": "You exceeded your realtime quota"}
        }))
        .unwrap(),
        ServerMessage::ErrorResponse {
            id: 7,
            code: VoiceErrorCode::Quota,
            message: "Realtime-Kontingent ist derzeit nicht verfuegbar.".to_string()
        }
    );
}

#[test]
fn malformed_protocol_message_is_rejected_without_echoing_content() {
    let error = classify_server_message(json!({"token": "secret-value"})).unwrap_err();
    assert_eq!(error.code, VoiceErrorCode::Protocol);
    assert!(!error.message.contains("secret-value"));
}
