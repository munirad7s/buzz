import * as React from "react";
import { createFileRoute } from "@tanstack/react-router";

import { usePreviewFeatureWarning } from "@/shared/features";

const EmpireCockpitScreen = React.lazy(async () => {
  const module = await import("@/features/empire/ui/EmpireCockpitScreen");
  return { default: module.EmpireCockpitScreen };
});

export const Route = createFileRoute("/empire")({
  component: EmpireRouteComponent,
});

function EmpireRouteComponent() {
  usePreviewFeatureWarning("empireCockpit");
  return (
    <React.Suspense
      fallback={
        <div className="p-6 text-sm text-muted-foreground">
          Empire-Cockpit wird geladen…
        </div>
      }
    >
      <EmpireCockpitScreen />
    </React.Suspense>
  );
}
