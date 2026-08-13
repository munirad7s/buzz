import assert from "node:assert/strict";
import test from "node:test";

import { createVoiceSession } from "./voiceSession.ts";

function createHarness({ failRemoteDescription = false } = {}) {
  const calls = [];
  const track = { stop: () => calls.push("track.stop") };
  const stream = { getTracks: () => [track] };
  const channel = {
    close: () => calls.push("channel.close"),
    onmessage: null,
  };
  const peer = {
    addTrack: () => calls.push("peer.addTrack"),
    close: () => calls.push("peer.close"),
    createDataChannel: (label) => {
      calls.push(["dataChannel", label]);
      return channel;
    },
    createOffer: async () => ({ type: "offer", sdp: "offer-sdp" }),
    ontrack: null,
    setLocalDescription: async ({ sdp }) =>
      calls.push(["localDescription", sdp]),
    setRemoteDescription: async ({ sdp }) => {
      calls.push(["remoteDescription", sdp]);
      if (failRemoteDescription) throw new Error("invalid answer");
    },
  };
  const audio = { autoplay: false, srcObject: null };
  const callbacks = {
    onSnapshot: (snapshot) => calls.push(["snapshot", snapshot]),
    onState: (state) => calls.push(["state", state]),
    onTranscript: (item) => calls.push(["transcript", item]),
  };
  const dependencies = {
    clearTimer: () => calls.push("timer.clear"),
    createAudio: () => audio,
    createPeer: () => peer,
    getUserMedia: async (constraints) => {
      calls.push(["media", constraints]);
      return stream;
    },
    setTimer: (_callback, timeout) => {
      calls.push(["timer.set", timeout]);
      return 1;
    },
    start: async (sdp) => {
      calls.push(["start", sdp]);
      return {
        sdpAnswer: "answer-sdp",
        snapshot: {
          gaps: ["relay unavailable"],
          text: "snapshot",
          truncated: false,
        },
        threadId: "thread-voice",
      };
    },
    stop: async (threadId) => calls.push(["stop", threadId]),
  };
  return { audio, callbacks, calls, channel, dependencies };
}

test("completes WebRTC negotiation and releases every resource", async () => {
  const harness = createHarness();
  const session = await createVoiceSession(
    harness.callbacks,
    harness.dependencies,
  );

  assert.deepEqual(harness.calls[0], ["state", "connecting"]);
  assert.deepEqual(harness.calls[1], [
    "media",
    {
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
      },
    },
  ]);
  assert(
    harness.calls.some(
      (call) => call[0] === "start" && call[1] === "offer-sdp",
    ),
  );
  assert(
    harness.calls.some(
      (call) => call[0] === "remoteDescription" && call[1] === "answer-sdp",
    ),
  );
  assert(
    harness.calls.some(
      (call) => call[0] === "state" && call[1] === "listening",
    ),
  );

  harness.channel.onmessage({
    data: JSON.stringify({
      transcript: "Three items need attention.",
      type: "response.audio_transcript.done",
    }),
  });
  assert(harness.calls.some((call) => call[0] === "transcript"));
  assert(
    harness.calls.some((call) => call[0] === "state" && call[1] === "speaking"),
  );

  await session.stop();
  assert(harness.calls.includes("channel.close"));
  assert(harness.calls.includes("peer.close"));
  assert(harness.calls.includes("track.stop"));
  assert(
    harness.calls.some(
      (call) => call[0] === "stop" && call[1] === "thread-voice",
    ),
  );
  assert.equal(harness.audio.srcObject, null);
});

test("failed answer setup stops the app-server session and local media", async () => {
  const harness = createHarness({ failRemoteDescription: true });

  await assert.rejects(
    createVoiceSession(harness.callbacks, harness.dependencies),
    /invalid answer/,
  );

  assert(harness.calls.includes("track.stop"));
  assert(
    harness.calls.some(
      (call) => call[0] === "stop" && call[1] === "thread-voice",
    ),
  );
});
