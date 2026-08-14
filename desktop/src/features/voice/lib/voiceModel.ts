export type VoiceTranscript = {
  speaker: "user" | "assistant";
  text: string;
  final: boolean;
};
export type VoiceUiError = {
  code: "permission" | "not_logged_in" | "entitlement" | "quota" | "protocol";
  title: string;
  detail: string;
};

export function normalizeRealtimeEvent(value: unknown): VoiceTranscript | null {
  if (!value || typeof value !== "object") return null;
  const event = value as Record<string, unknown>;
  const type = String(event.type ?? "");
  const user = type.includes("input_audio_transcription");
  const assistant = type.includes("audio_transcript") && !user;
  if (!user && !assistant) return null;
  const text = String(event.delta ?? event.transcript ?? "").trim();
  if (!text) return null;
  return {
    speaker: user ? "user" : "assistant",
    text,
    final: type.endsWith(".done") || type.endsWith(".completed"),
  };
}

export function classifyVoiceError(error: unknown): VoiceUiError {
  const record =
    error && typeof error === "object"
      ? (error as Record<string, unknown>)
      : {};
  const name = String(record.name ?? "");
  const code = String(record.code ?? "");
  if (name === "NotAllowedError")
    return {
      code: "permission",
      title: "Mikrofon blockiert",
      detail: "Mikrofonzugriff in Windows oder WebView freigeben.",
    };
  if (code === "not_logged_in")
    return {
      code: "not_logged_in",
      title: "ChatGPT nicht verbunden",
      detail: "Codex zuerst mit ChatGPT anmelden.",
    };
  if (code === "entitlement")
    return {
      code: "entitlement",
      title: "Voice nicht freigeschaltet",
      detail: "Realtime-Entitlement fehlt. Kein bezahlter Fallback.",
    };
  if (code === "quota")
    return {
      code: "quota",
      title: "Kontingent nicht verfügbar",
      detail: "Später erneut versuchen. Kein Spend oder API-Fallback.",
    };
  return {
    code: "protocol",
    title: "Verbindung fehlgeschlagen",
    detail: "Voice-Session sauber beendet. Erneut versuchen.",
  };
}
