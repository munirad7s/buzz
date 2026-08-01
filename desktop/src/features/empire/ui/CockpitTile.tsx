import { AlertTriangle, CircleAlert, CircleCheck } from "lucide-react";

import type { CockpitTile as CockpitTileModel } from "@/features/empire/lib/cockpitModel";
import { Badge } from "@/shared/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/shared/ui/card";
import { cn } from "@/shared/lib/cn";

/**
 * One cockpit tile (buzz#15).
 *
 * The visual grammar carries the doctrine: a gap tile renders "nicht erhoben"
 * where the number would be, in the destructive colour, with the reason and the
 * command to fix it. It must be impossible to mistake for a calm zero — that
 * confusion is the exact failure this feature was built to prevent.
 */
export function CockpitTile({ tile }: { tile: CockpitTileModel }) {
  const isGap = tile.status === "gap";
  const isWarn = tile.status === "warn";

  return (
    <Card
      className={cn(
        "flex min-w-0 flex-col border",
        isGap && "border-destructive/60 bg-destructive/5",
        isWarn && "border-amber-500/50",
      )}
      data-testid={`empire-tile-${tile.id}`}
      data-status={tile.status}
    >
      <CardHeader className="flex flex-row items-center justify-between gap-2 space-y-0 pb-2">
        <CardTitle className="text-sm font-semibold tracking-tight">
          {tile.title}
        </CardTitle>
        <StatusBadge status={tile.status} />
      </CardHeader>
      <CardContent className="flex min-w-0 flex-1 flex-col gap-3">
        <div className="min-w-0">
          {tile.headline === null ? (
            <p
              className="text-2xl font-semibold tracking-tight text-destructive"
              data-testid={`empire-tile-${tile.id}-gap`}
            >
              nicht erhoben
            </p>
          ) : (
            <p
              className="text-3xl font-semibold tabular-nums tracking-tight"
              data-testid={`empire-tile-${tile.id}-headline`}
            >
              {tile.headline}
            </p>
          )}
          <p className="text-xs text-muted-foreground">{tile.subline}</p>
        </div>

        {tile.lines.length > 0 ? (
          <ul className="min-w-0 space-y-1 text-xs">
            {tile.lines.map((line) => (
              <li
                key={`${line.label}-${line.value}`}
                className="flex min-w-0 items-baseline justify-between gap-3"
              >
                <span className="shrink-0 text-muted-foreground">
                  {line.label}
                </span>
                {line.href ? (
                  <a
                    className={cn(
                      "min-w-0 truncate text-right underline-offset-4 hover:underline",
                      line.emphasis &&
                        "font-medium text-amber-600 dark:text-amber-400",
                    )}
                    href={line.href}
                    rel="noreferrer"
                    target="_blank"
                    title={line.value}
                  >
                    {line.value}
                  </a>
                ) : (
                  <span
                    className={cn(
                      "min-w-0 truncate text-right tabular-nums",
                      line.emphasis &&
                        "font-medium text-amber-600 dark:text-amber-400",
                      line.value === "nicht erhoben" && "text-destructive",
                    )}
                    title={line.value}
                  >
                    {line.value}
                  </span>
                )}
              </li>
            ))}
          </ul>
        ) : null}

        {tile.reason ? (
          <p
            className={cn(
              "text-xs leading-snug",
              isGap ? "text-destructive" : "text-muted-foreground",
            )}
            data-testid={`empire-tile-${tile.id}-reason`}
          >
            {tile.reason}
          </p>
        ) : null}

        {tile.hint ? (
          <code className="block overflow-x-auto rounded bg-muted/70 px-2 py-1 text-2xs text-muted-foreground">
            {tile.hint}
          </code>
        ) : null}
      </CardContent>
    </Card>
  );
}

function StatusBadge({ status }: { status: CockpitTileModel["status"] }) {
  if (status === "gap") {
    return (
      <Badge variant="destructive">
        <CircleAlert className="mr-1 h-3 w-3" />
        Lücke
      </Badge>
    );
  }
  if (status === "warn") {
    return (
      <Badge variant="warning">
        <AlertTriangle className="mr-1 h-3 w-3" />
        Achtung
      </Badge>
    );
  }
  return (
    <Badge variant="success">
      <CircleCheck className="mr-1 h-3 w-3" />
      gemessen
    </Badge>
  );
}
