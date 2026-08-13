import assert from "node:assert/strict";
import test from "node:test";

import { classifyVoiceError, normalizeRealtimeEvent } from "./voiceModel.ts";

test("normalizes user transcript deltas", () => {
  assert.deepEqual(
    normalizeRealtimeEvent({
      type: "conversation.item.input_audio_transcription.delta",
      delta: "Hello",
    }),
    { speaker: "user", text: "Hello", final: false },
  );
});

test("normalizes assistant audio transcript completion", () => {
  assert.deepEqual(
    normalizeRealtimeEvent({
      type: "response.audio_transcript.done",
      transcript: "Three items need attention.",
    }),
    {
      speaker: "assistant",
      text: "Three items need attention.",
      final: true,
    },
  );
});

test("ignores unrelated realtime events", () => {
  assert.equal(normalizeRealtimeEvent({ type: "rate_limits.updated" }), null);
});

test("classifies permission, login, entitlement, quota and protocol errors", () => {
  assert.equal(
    classifyVoiceError({ name: "NotAllowedError" }).code,
    "permission",
  );
  assert.equal(
    classifyVoiceError({ code: "not_logged_in" }).code,
    "not_logged_in",
  );
  assert.equal(classifyVoiceError({ code: "entitlement" }).code, "entitlement");
  assert.equal(classifyVoiceError({ code: "quota" }).code, "quota");
  assert.equal(classifyVoiceError(new Error("bad sdp")).code, "protocol");
});
