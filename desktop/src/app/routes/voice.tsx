import * as React from "react";
import { createFileRoute } from "@tanstack/react-router";
import { usePreviewFeatureWarning } from "@/shared/features";

const VoicePanelScreen = React.lazy(async () => ({
  default: (await import("@/features/voice/ui/VoicePanelScreen"))
    .VoicePanelScreen,
}));
export const Route = createFileRoute("/voice")({ component: VoiceRoute });
function VoiceRoute() {
  usePreviewFeatureWarning("voicePanel");
  return (
    <React.Suspense
      fallback={
        <div className="p-6 text-sm text-muted-foreground">
          Voice wird geladen…
        </div>
      }
    >
      <VoicePanelScreen />
    </React.Suspense>
  );
}
