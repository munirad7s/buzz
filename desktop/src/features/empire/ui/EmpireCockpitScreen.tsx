import * as React from "react";
import { RefreshCw } from "lucide-react";

import { CockpitTile } from "@/features/empire/ui/CockpitTile";
import {
  useEmpireAgentRuntimes,
  useEmpireSnapshotQuery,
  useRefreshEmpireSnapshot,
} from "@/features/empire/hooks";
import {
  buildCockpitTiles,
  snapshotAge,
  type SnapshotEnvelope,
} from "@/features/empire/lib/cockpitModel";
import { Button } from "@/shared/ui/button";
import { PageHeader } from "@/shared/ui/PageHeader";

/**
 * Empire cockpit (buzz#15) — four tiles, one screen, no invented numbers.
 *
 * Reading the snapshot on open is free (one local file). The refresh button is
 * the only path that costs GitHub calls, and it is never fired by an effect.
 */
export function EmpireCockpitScreen() {
  const snapshotQuery = useEmpireSnapshotQuery();
  const agents = useEmpireAgentRuntimes();
  const refresh = useRefreshEmpireSnapshot();

  const envelope: SnapshotEnvelope | null = snapshotQuery.data ?? null;

  // While a source is still loading we render nothing rather than a placeholder
  // number — a skeleton that later turns into a real figure is honest, a "0"
  // that later turns into a real figure is not.
  const tiles = React.useMemo(() => {
    if (!envelope || !agents.source) return null;
    return buildCockpitTiles(envelope, agents.source);
  }, [envelope, agents.source]);

  const age = envelope ? snapshotAge(envelope) : null;

  return (
    <div className="flex h-full min-h-0 flex-col overflow-y-auto">
      <div className="mx-auto w-full max-w-5xl space-y-6 px-6 py-8">
        <PageHeader
          action={
            <Button
              disabled={refresh.isPending}
              onClick={() => refresh.mutate()}
              size="sm"
              type="button"
              variant="outline"
            >
              <RefreshCw
                className={refresh.isPending ? "animate-spin" : undefined}
              />
              {refresh.isPending ? "Sammler läuft…" : "Neu erheben"}
            </Button>
          }
          description="Vier Kacheln aus echten Quellen. Was nicht gemessen wurde, steht als Lücke — nie als 0."
          title="Empire-Cockpit"
        />

        <SourceLine
          age={age}
          envelope={envelope}
          isLoading={snapshotQuery.isPending}
        />

        {refresh.isError ? (
          <p className="text-sm text-destructive">
            Sammler nicht ausführbar:{" "}
            {refresh.error instanceof Error
              ? refresh.error.message
              : String(refresh.error)}
          </p>
        ) : null}
        {envelope?.collector && !envelope.collector.wroteSnapshot ? (
          <p className="text-sm text-destructive">
            Sammler beendet ohne neuen Stand (exit{" "}
            {envelope.collector.exitCode ?? "—"}) — die Kacheln zeigen den
            vorherigen Stand. {envelope.collector.message}
          </p>
        ) : null}

        {tiles === null ? (
          <p className="text-sm text-muted-foreground">
            Quellen werden gelesen…
          </p>
        ) : (
          <div className="grid gap-4 sm:grid-cols-2">
            {tiles.map((tile) => (
              <CockpitTile key={tile.id} tile={tile} />
            ))}
          </div>
        )}

        <p className="text-xs leading-relaxed text-muted-foreground">
          Gates und Backlog kommen aus dem Empire-Sammler (
          <code>.empire/tools/cockpit-snapshot.sh</code>, gespeist von{" "}
          <code>lagebild.sh</code>), Agenten direkt aus der Desktop-Laufzeit,
          Rituale aus den Lauf-Quittungen von <code>ritual.sh</code>. Keine Zahl
          auf dieser Seite stammt aus einem Modell.
        </p>
      </div>
    </div>
  );
}

function SourceLine({
  age,
  envelope,
  isLoading,
}: {
  age: ReturnType<typeof snapshotAge> | null;
  envelope: SnapshotEnvelope | null;
  isLoading: boolean;
}) {
  if (isLoading) {
    return (
      <p className="text-xs text-muted-foreground">Snapshot wird gelesen…</p>
    );
  }
  if (!envelope) {
    return (
      <p className="text-xs text-destructive">
        Snapshot-Quelle nicht abfragbar — die Kacheln unten sind Lücken, keine
        Nullen.
      </p>
    );
  }
  return (
    <p className="text-xs text-muted-foreground">
      Quelle: <code>{envelope.path}</code>
      {age ? (
        <>
          {" · "}
          <span
            className={
              age.stale
                ? "font-medium text-amber-600 dark:text-amber-400"
                : undefined
            }
          >
            Stand {age.label}
          </span>
        </>
      ) : null}
    </p>
  );
}
