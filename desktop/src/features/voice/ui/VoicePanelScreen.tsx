import * as React from "react";
import { AlertTriangle, LockKeyhole, Mic, Radio, Square } from "lucide-react";
import { motion, useReducedMotion } from "motion/react";

import { createVoiceSession } from "@/features/voice/lib/voiceSession";
import {
  classifyVoiceError,
  type VoiceTranscript,
} from "@/features/voice/lib/voiceModel";
import type { VoiceSnapshot } from "@/shared/api/tauriVoice";
import { Button } from "@/shared/ui/button";
import { Card } from "@/shared/ui/card";
import { PageHeader } from "@/shared/ui/PageHeader";

type State =
  | "idle"
  | "connecting"
  | "listening"
  | "speaking"
  | "stopping"
  | "error";

export function VoicePanelScreen() {
  const [state, setState] = React.useState<State>("idle");
  const [startedAt, setStartedAt] = React.useState(0);
  const [elapsed, setElapsed] = React.useState(0);
  const [transcript, setTranscript] = React.useState<VoiceTranscript[]>([]);
  const [snapshot, setSnapshot] = React.useState<VoiceSnapshot | null>(null);
  const [error, setError] = React.useState<ReturnType<
    typeof classifyVoiceError
  > | null>(null);
  const session = React.useRef<{ stop: () => Promise<void> } | null>(null);
  const sessionGeneration = React.useRef(0);
  const reducedMotion = useReducedMotion();

  React.useEffect(() => {
    if (!startedAt || state === "idle" || state === "error") return;
    const update = () =>
      setElapsed(Math.floor((Date.now() - startedAt) / 1000));
    update();
    const timer = window.setInterval(update, 1000);
    return () => window.clearInterval(timer);
  }, [startedAt, state]);

  React.useEffect(
    () => () => {
      sessionGeneration.current += 1;
      void session.current?.stop();
    },
    [],
  );

  const start = async () => {
    const generation = ++sessionGeneration.current;
    setError(null);
    setTranscript([]);
    setSnapshot(null);
    setStartedAt(Date.now());
    setState("connecting");
    try {
      const nextSession = await createVoiceSession({
        onState: (nextState) => {
          if (generation === sessionGeneration.current) setState(nextState);
        },
        onTranscript: (item) =>
          generation === sessionGeneration.current &&
          setTranscript((items) => [...items.slice(-5), item]),
        onSnapshot: (nextSnapshot) => {
          if (generation === sessionGeneration.current)
            setSnapshot(nextSnapshot);
        },
      });
      if (generation !== sessionGeneration.current) {
        await nextSession.stop();
        return;
      }
      session.current = nextSession;
    } catch (cause) {
      if (generation !== sessionGeneration.current) return;
      setError(classifyVoiceError(cause));
      setState("error");
    }
  };
  const stop = async () => {
    sessionGeneration.current += 1;
    setState("stopping");
    await session.current?.stop();
    session.current = null;
    setState("idle");
    setStartedAt(0);
    setElapsed(0);
  };
  const active = ["listening", "speaking", "stopping"].includes(state);
  const time = `${String(Math.floor(elapsed / 60)).padStart(2, "0")}:${String(elapsed % 60).padStart(2, "0")}`;

  return (
    <div className="relative h-full min-h-0 overflow-y-auto bg-[#0b0d0f] text-stone-100">
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 opacity-[0.055] [background-image:url('data:image/svg+xml,%3Csvg viewBox=%270 0 180 180%27 xmlns=%27http://www.w3.org/2000/svg%27%3E%3Cfilter id=%27n%27%3E%3CfeTurbulence type=%27fractalNoise%27 baseFrequency=%27.9%27 numOctaves=%273%27/%3E%3C/filter%3E%3Crect width=%27100%25%27 height=%27100%25%27 filter=%27url(%23n)%27/%3E%3C/svg%3E')]"
      />
      <main className="relative mx-auto w-full max-w-6xl space-y-6 px-5 py-7 lg:px-8">
        <PageHeader
          title="Voice"
          description="Sprich mit deinem aktuellen Buzz-Lagebild — über ChatGPT, read-only und ohne API-Spend."
        />
        <div className="grid gap-5 lg:grid-cols-[minmax(0,1.35fr)_minmax(18rem,.65fr)]">
          <Card
            className={`relative overflow-hidden border-stone-800 bg-[#111416]/95 p-6 sm:p-8 ${active ? "shadow-[0_0_0_1px_rgba(245,174,54,.65),0_0_55px_rgba(245,174,54,.10)]" : ""}`}
          >
            <div className="mb-10 flex items-center justify-between text-xs uppercase tracking-[.2em] text-stone-500">
              <span>
                {state === "speaking"
                  ? "Assistant spricht"
                  : state === "listening"
                    ? "Hört zu"
                    : state === "connecting"
                      ? "Verbindet"
                      : "Bereit"}
              </span>
              <span>{time}</span>
            </div>
            <div className="flex min-h-80 flex-col items-center justify-center text-center">
              <motion.div
                animate={
                  active && !reducedMotion
                    ? { scale: [1, 1.035, 1] }
                    : undefined
                }
                transition={{ duration: 2.4, repeat: Number.POSITIVE_INFINITY }}
                className={`grid size-44 place-items-center rounded-full border ${active ? "border-amber-400/80 bg-amber-400/[.07] text-amber-300 shadow-[0_0_60px_rgba(245,174,54,.16)]" : "border-stone-700 bg-black/20 text-stone-400"}`}
              >
                {state === "speaking" ? (
                  <Radio className="size-16" />
                ) : (
                  <Mic className="size-16" />
                )}
              </motion.div>
              <p
                aria-live="polite"
                className="mt-7 text-xl font-medium tracking-wide"
              >
                {error?.title ??
                  (state === "connecting"
                    ? "Codex Realtime wird verbunden"
                    : state === "speaking"
                      ? "Antwort läuft"
                      : state === "listening"
                        ? "Ich höre zu"
                        : state === "stopping"
                          ? "Session wird beendet"
                          : "Bereit für deinen Morgenbrief")}
              </p>
              {error ? (
                <p className="mt-3 max-w-md text-sm text-amber-200/70">
                  {error.detail}
                </p>
              ) : null}
              <Button
                className="mt-8 h-14 min-w-52 border-amber-400/60 bg-transparent text-amber-200 hover:bg-amber-400/10"
                disabled={state === "connecting" || state === "stopping"}
                onClick={() => void (active ? stop() : start())}
                type="button"
                variant="outline"
              >
                {active ? (
                  <>
                    <Square /> Stoppen
                  </>
                ) : (
                  <>
                    <Mic /> Voice starten
                  </>
                )}
              </Button>
            </div>
          </Card>
          <div className="space-y-5">
            <Card className="border-stone-800 bg-[#111416]/90 p-5">
              <div className="flex items-center gap-2 text-sm font-medium">
                <LockKeyhole className="size-4 text-amber-300" /> Read only
              </div>
              <p className="mt-2 text-sm leading-relaxed text-stone-500">
                Keine Tools, Freigaben, Sends oder Writes. Mutationen bleiben in
                Buzz-Gates.
              </p>
            </Card>
            <Card className="border-stone-800 bg-[#111416]/90 p-5">
              <h2 className="text-xs uppercase tracking-[.18em] text-stone-500">
                Snapshot
              </h2>
              <p className="mt-3 text-sm text-stone-300">
                {snapshot
                  ? `${snapshot.gaps.length} ${snapshot.gaps.length === 1 ? "Lücke" : "Lücken"} · ${snapshot.truncated ? "gekürzt" : "vollständig"}`
                  : "Wird beim Start lokal erhoben"}
              </p>
              {snapshot?.gaps.map((gap) => (
                <div
                  className="mt-3 flex gap-2 text-xs leading-relaxed text-amber-200/70"
                  key={gap}
                >
                  <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
                  {gap}
                </div>
              ))}
            </Card>
            <Card className="min-h-64 border-stone-800 bg-[#111416]/90 p-5">
              <h2 className="text-xs uppercase tracking-[.18em] text-stone-500">
                Transcript
              </h2>
              <div className="mt-4 space-y-4">
                {transcript.length ? (
                  transcript.map((item) => (
                    <div key={`${item.speaker}-${item.text}-${item.final}`}>
                      <p className="text-[.65rem] uppercase tracking-[.18em] text-amber-300/80">
                        {item.speaker === "user" ? "Du" : "Assistant"}
                      </p>
                      <p className="mt-1 text-sm leading-relaxed text-stone-300">
                        {item.text}
                      </p>
                    </div>
                  ))
                ) : (
                  <p className="text-sm text-stone-600">Noch kein Gespräch.</p>
                )}
              </div>
            </Card>
          </div>
        </div>
      </main>
    </div>
  );
}
