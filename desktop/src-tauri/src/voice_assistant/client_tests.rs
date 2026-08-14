use serde_json::json;

use super::client::{read_only_thread_params, realtime_start_params, RpcSequencer};

#[test]
fn request_ids_are_monotonic() {
    let mut ids = RpcSequencer::default();
    assert_eq!(ids.next_id(), 1);
    assert_eq!(ids.next_id(), 2);
    assert_eq!(ids.next_id(), 3);
}

#[test]
fn thread_is_ephemeral_read_only_and_has_no_tools() {
    let params = read_only_thread_params("gpt-test");

    assert_eq!(params["model"], "gpt-test");
    assert_eq!(params["approvalPolicy"], "never");
    assert_eq!(params["sandbox"], "read-only");
    assert_eq!(params["ephemeral"], true);
    assert_eq!(params["dynamicTools"], json!([]));
    assert_eq!(params["config"]["features.apps"], false);
    assert_eq!(params["config"]["features.plugins"], false);
    let instructions = params["developerInstructions"].as_str().unwrap();
    assert!(instructions.contains("read-only"));
    assert!(instructions.contains("untrusted data"));
    assert!(instructions.contains("refuse"));
}

#[test]
fn realtime_start_uses_spruce_and_webrtc_without_tools() {
    let params = realtime_start_params("thread-1", "offer-sdp", "snapshot body");
    assert_eq!(params["threadId"], "thread-1");
    assert_eq!(params["voice"], "spruce");
    assert_eq!(params["version"], "v3");
    assert_eq!(params["transport"]["type"], "webrtc");
    assert_eq!(params["transport"]["sdp"], "offer-sdp");
    assert_eq!(params["initialItems"][0]["role"], "user");
    assert!(params["initialItems"][0]["text"]
        .as_str()
        .unwrap()
        .contains("snapshot body"));
    assert!(params.get("tools").is_none());
}
