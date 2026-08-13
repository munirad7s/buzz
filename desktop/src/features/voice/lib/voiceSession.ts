import {
  startVoice,
  stopVoice,
  type VoiceSnapshot,
} from "@/shared/api/tauriVoice";
import { normalizeRealtimeEvent, type VoiceTranscript } from "./voiceModel";

export type VoiceCallbacks = {
  onState: (state: "connecting" | "listening" | "speaking") => void;
  onTranscript: (item: VoiceTranscript) => void;
  onSnapshot: (snapshot: VoiceSnapshot) => void;
};

type VoiceDependencies = {
  createAudio: () => HTMLAudioElement;
  createPeer: () => RTCPeerConnection;
  getUserMedia: (constraints: MediaStreamConstraints) => Promise<MediaStream>;
  setTimer: typeof setTimeout;
  clearTimer: typeof clearTimeout;
  start: typeof startVoice;
  stop: typeof stopVoice;
};

const browserDependencies: VoiceDependencies = {
  createAudio: () => new Audio(),
  createPeer: () => new RTCPeerConnection(),
  getUserMedia: (constraints) =>
    navigator.mediaDevices.getUserMedia(constraints),
  setTimer: (callback, delay) => setTimeout(callback, delay),
  clearTimer: (timer) => clearTimeout(timer),
  start: startVoice,
  stop: stopVoice,
};

export async function createVoiceSession(
  callbacks: VoiceCallbacks,
  dependencies: VoiceDependencies = browserDependencies,
) {
  callbacks.onState("connecting");
  const stream = await dependencies.getUserMedia({
    audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
  });
  const peer = dependencies.createPeer();
  const channel = peer.createDataChannel("oai-events");
  const audio = dependencies.createAudio();
  audio.autoplay = true;
  peer.ontrack = ({ streams }) => {
    audio.srcObject = streams[0] ?? null;
  };
  stream.getTracks().forEach((track) => {
    peer.addTrack(track, stream);
  });
  let threadId: string | null = null;
  let timer: ReturnType<typeof setTimeout>;
  const cleanupLocal = () => {
    dependencies.clearTimer(timer);
    channel.close();
    peer.close();
    stream.getTracks().forEach((track) => {
      track.stop();
    });
    audio.srcObject = null;
  };
  const arm = () => {
    dependencies.clearTimer(timer);
    timer = dependencies.setTimer(() => void stop(), 45_000);
  };
  channel.onmessage = ({ data }) => {
    try {
      const event = JSON.parse(String(data));
      const item = normalizeRealtimeEvent(event);
      if (item) {
        callbacks.onTranscript(item);
        callbacks.onState(
          item.speaker === "assistant" ? "speaking" : "listening",
        );
        arm();
      }
    } catch {
      /* ignore non-json events */
    }
  };
  const stop = async () => {
    cleanupLocal();
    if (threadId) await dependencies.stop(threadId).catch(() => undefined);
    threadId = null;
  };
  try {
    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    const result = await dependencies.start(offer.sdp ?? "");
    threadId = result.threadId;
    callbacks.onSnapshot(result.snapshot);
    await peer.setRemoteDescription({ type: "answer", sdp: result.sdpAnswer });
    callbacks.onState("listening");
    arm();
    return { stop };
  } catch (error) {
    cleanupLocal();
    if (threadId) await dependencies.stop(threadId).catch(() => undefined);
    throw error;
  }
}
