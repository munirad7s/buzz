import { invokeTauri } from "@/shared/api/tauri";

export type VoiceSnapshot = {
  generatedAt: string;
  content: string;
  truncated: boolean;
  gaps: string[];
};
export type VoiceStartResponse = {
  threadId: string;
  sdpAnswer: string;
  snapshot: VoiceSnapshot;
};
export const startVoice = (sdp: string) =>
  invokeTauri<VoiceStartResponse>("voice_start", { sdp });
export const stopVoice = (threadId: string) =>
  invokeTauri<void>("voice_stop", { threadId });
