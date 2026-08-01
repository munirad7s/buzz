/**
 * Empire cockpit — turning raw sources into tiles (buzz#15).
 *
 * This module is the whole point of the feature and deliberately holds every
 * judgement call, so the judgement can be tested without a browser.
 *
 * # The rule
 *
 * A tile shows a number only when that number was measured. Anything else —
 * source missing, snapshot unparseable, collector never run, block reporting
 * its own failure, snapshot too old to trust — becomes `status: "gap"` with a
 * named reason. There is no code path that turns "unknown" into `0`.
 *
 * That is not pedantry. On 2026-08-01 a report announced "no gate open"
 * because its data source was missing; the reassuring zero was indistinguishable
 * from the true zero. A cockpit repeats that mistake four times a screen.
 */

export type TileStatus = "ok" | "warn" | "gap";

export type TileLine = {
  label: string;
  value: string;
  /** Optional link target, e.g. the GitHub issue behind a gate. */
  href?: string;
  /** Marks the entry as needing attention (rendered in the accent colour). */
  emphasis?: boolean;
};

export type CockpitTile = {
  id: "gates" | "backlog" | "agents" | "rituals";
  title: string;
  status: TileStatus;
  /** Headline number. `null` whenever it was not measured — never `0`. */
  headline: string | null;
  /** One line under the headline. Present in every state. */
  subline: string;
  lines: TileLine[];
  /** Why the tile is a gap or a warning. `null` only when `status === "ok"`. */
  reason: string | null;
  /** What a human should do about it. Only set for gaps. */
  hint: string | null;
};

export type SnapshotEnvelope = {
  path: string;
  snapshot: Record<string, unknown> | null;
  readError: string | null;
  fileModifiedAt: string | null;
  readAt: string;
  refreshHint: string;
  collector?: {
    script: string;
    exitCode: number | null;
    wroteSnapshot: boolean;
    message: string;
  };
};

export type AgentRuntime = {
  pubkey: string;
  lifecycle: string;
  error?: string | null;
};

export type AgentRuntimeSource =
  | { state: "ok"; runtimes: AgentRuntime[] }
  | { state: "error"; message: string };

/**
 * How old a snapshot may be before its numbers stop counting as "current".
 *
 * Chosen against the ritual cadence, not taste: the morning brief runs at
 * 08:45 and the gate batch at 20:45 Europe/Berlin, so a snapshot older than
 * half a day has certainly missed a leadership cycle. Past this line the tile
 * keeps showing the number but flags it — an old measurement is still a
 * measurement, silently presenting it as current is the lie.
 */
export const STALE_AFTER_MS = 12 * 60 * 60 * 1000;

const SCHEMA_VERSION = 1;

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asNonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim().length > 0
    ? value.trim()
    : null;
}

/** Human-readable age, e.g. "vor 3 min" / "vor 2 h 5 min". */
export function formatAge(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return "unbekannt";
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 1) return "gerade eben";
  if (minutes < 60) return `vor ${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours < 24)
    return rest > 0 ? `vor ${hours} h ${rest} min` : `vor ${hours} h`;
  const days = Math.floor(hours / 24);
  return `vor ${days} ${days === 1 ? "Tag" : "Tagen"}`;
}

export type SnapshotAge = {
  ms: number | null;
  label: string;
  stale: boolean;
};

export function snapshotAge(envelope: SnapshotEnvelope): SnapshotAge {
  const modified = envelope.fileModifiedAt
    ? Date.parse(envelope.fileModifiedAt)
    : Number.NaN;
  const read = Date.parse(envelope.readAt);
  if (!Number.isFinite(modified) || !Number.isFinite(read)) {
    // No usable timestamp means we cannot claim freshness. Treat it as stale:
    // the safe direction is "distrust the number", not "assume it is current".
    return { ms: null, label: "Alter unbekannt", stale: true };
  }
  const ms = Math.max(0, read - modified);
  return { ms, label: formatAge(ms), stale: ms > STALE_AFTER_MS };
}

type BlockResult =
  | { ok: true; block: Record<string, unknown> }
  | { ok: false; reason: string; hint: string };

/**
 * Pulls one block out of the envelope, refusing every ambiguous case.
 *
 * Order matters: an unreadable envelope must never fall through to "block
 * missing", because the two need different fixes.
 */
function readBlock(envelope: SnapshotEnvelope, name: string): BlockResult {
  if (envelope.readError) {
    return {
      ok: false,
      reason: envelope.readError,
      hint: envelope.refreshHint,
    };
  }
  const snapshot = asRecord(envelope.snapshot);
  if (!snapshot) {
    return {
      ok: false,
      reason: "Snapshot leer oder kein Objekt — nichts erhoben",
      hint: envelope.refreshHint,
    };
  }
  const version = asFiniteNumber(snapshot.schema_version);
  if (version !== SCHEMA_VERSION) {
    return {
      ok: false,
      reason: `Snapshot-Schema ${version ?? "fehlt"} — erwartet ${SCHEMA_VERSION}; Zahlen werden NICHT interpretiert`,
      hint: envelope.refreshHint,
    };
  }
  const block = asRecord(snapshot[name]);
  if (!block) {
    return {
      ok: false,
      reason: `Block "${name}" fehlt im Snapshot`,
      hint: envelope.refreshHint,
    };
  }
  const state = asNonEmptyString(block.state);
  if (state === "error" || state === null) {
    return {
      ok: false,
      reason:
        asNonEmptyString(block.reason) ??
        `Block "${name}" meldet sich als nicht erhoben`,
      hint: envelope.refreshHint,
    };
  }
  return { ok: true, block };
}

function gapTile(
  id: CockpitTile["id"],
  title: string,
  reason: string,
  hint: string,
): CockpitTile {
  return {
    id,
    title,
    status: "gap",
    headline: null,
    subline: "nicht erhoben",
    lines: [],
    reason,
    hint,
  };
}

function staleNote(age: SnapshotAge): string {
  return `Stand ${age.label} — älter als ${STALE_AFTER_MS / 3_600_000} h, Zahlen sind womöglich überholt`;
}

/** Tile (a): open Munir gates — the held-revenue tile. */
export function buildGatesTile(
  envelope: SnapshotEnvelope,
  age: SnapshotAge,
): CockpitTile {
  const result = readBlock(envelope, "backlog");
  if (!result.ok) {
    return gapTile("gates", "Gates", result.reason, result.hint);
  }
  const blocked = asFiniteNumber(result.block.blocked);
  if (blocked === null) {
    return gapTile(
      "gates",
      "Gates",
      "Backlog-Block ohne Feld `blocked` — Gate-Zahl UNBEKANNT (nicht 0)",
      envelope.refreshHint,
    );
  }
  const top = Array.isArray(result.block.top_blocked)
    ? result.block.top_blocked
    : [];
  const lines: TileLine[] = top.flatMap((entry) => {
    const row = asRecord(entry);
    if (!row) return [];
    const repo = asNonEmptyString(row.repo) ?? "?";
    const number = asFiniteNumber(row.number);
    const title = asNonEmptyString(row.title) ?? "(ohne Titel)";
    const prio = asNonEmptyString(row.prio) ?? "ohne";
    return [
      {
        label: `${prio} · ${repo}#${number ?? "?"}`,
        value: title,
        href: asNonEmptyString(row.url) ?? undefined,
        emphasis: prio === "P1-money",
      },
    ];
  });

  const partial = asNonEmptyString(result.block.reason);
  return {
    id: "gates",
    title: "Gates",
    status: age.stale ? "warn" : blocked > 0 ? "warn" : partial ? "warn" : "ok",
    headline: String(blocked),
    subline:
      blocked === 0
        ? "kein Gate offen — gemessen, nicht angenommen"
        : `${blocked} Entscheidung(en) warten auf Munir`,
    lines,
    reason: age.stale ? staleNote(age) : partial,
    hint: null,
  };
}

/** Tile (b): ready backlog per priority. */
export function buildBacklogTile(
  envelope: SnapshotEnvelope,
  age: SnapshotAge,
): CockpitTile {
  const result = readBlock(envelope, "backlog");
  if (!result.ok) {
    return gapTile("backlog", "Backlog", result.reason, result.hint);
  }
  const total = asFiniteNumber(result.block.ready_total);
  const byPrio = asRecord(result.block.by_prio);
  if (total === null || !byPrio) {
    return gapTile(
      "backlog",
      "Backlog",
      "Backlog-Block ohne ready_total/by_prio — Bestand UNBEKANNT (nicht 0)",
      envelope.refreshHint,
    );
  }

  const order = ["P1-money", "P1", "P2", "P3", "ohne"] as const;
  const lines: TileLine[] = order.flatMap((prio) => {
    const count = asFiniteNumber(byPrio[prio]);
    // A priority the collector did not report is shown as unknown, not as 0.
    return [
      {
        label: prio,
        value: count === null ? "nicht erhoben" : String(count),
        emphasis: prio === "P1-money" && (count ?? 0) > 0,
      },
    ];
  });

  const inProgress = asFiniteNumber(result.block.in_progress);
  lines.push({
    label: "in-progress",
    value: inProgress === null ? "nicht erhoben" : String(inProgress),
  });

  const reposRead = asFiniteNumber(result.block.repos_read);
  const reposExpected = asFiniteNumber(result.block.repos_expected);
  const partial = asNonEmptyString(result.block.reason);
  const incomplete =
    reposRead !== null && reposExpected !== null && reposRead < reposExpected;

  return {
    id: "backlog",
    title: "Backlog (ready)",
    status: age.stale || partial || incomplete ? "warn" : "ok",
    headline: String(total),
    subline:
      reposRead === null || reposExpected === null
        ? "Repo-Abdeckung unbekannt"
        : `aus ${reposRead}/${reposExpected} Repos`,
    lines,
    reason: age.stale
      ? staleNote(age)
      : incomplete
        ? `nur ${reposRead}/${reposExpected} Repos gelesen — die Summe ist eine Untergrenze`
        : partial,
    hint: null,
  };
}

const RUNNING_LIFECYCLES = new Set(["ready", "listening", "waking"]);
const STARTING_LIFECYCLES = new Set(["starting"]);
const FAILED_LIFECYCLES = new Set(["failed"]);

/** Tile (c): managed-agent runtime, straight from the desktop process. */
export function buildAgentsTile(source: AgentRuntimeSource): CockpitTile {
  if (source.state === "error") {
    return gapTile(
      "agents",
      "Agenten",
      `Laufzeit nicht abfragbar: ${source.message}`,
      "Agents-Tab öffnen — die Laufzeit antwortet dem Cockpit gerade nicht",
    );
  }
  const runtimes = source.runtimes;
  let running = 0;
  let starting = 0;
  let failed = 0;
  let stopped = 0;
  let unknown = 0;
  for (const runtime of runtimes) {
    const lifecycle = (runtime.lifecycle ?? "").toLowerCase();
    if (RUNNING_LIFECYCLES.has(lifecycle)) running += 1;
    else if (STARTING_LIFECYCLES.has(lifecycle)) starting += 1;
    else if (FAILED_LIFECYCLES.has(lifecycle)) failed += 1;
    else if (lifecycle === "stopped") stopped += 1;
    // An unmapped lifecycle is counted separately rather than silently folded
    // into "stopped" — a new upstream state must be visible, not absorbed.
    else unknown += 1;
  }

  const lines: TileLine[] = [
    { label: "laufend", value: String(running) },
    { label: "startend", value: String(starting) },
    { label: "fehlerhaft", value: String(failed), emphasis: failed > 0 },
    { label: "gestoppt", value: String(stopped) },
  ];
  if (unknown > 0) {
    lines.push({
      label: "unbekannter Zustand",
      value: String(unknown),
      emphasis: true,
    });
  }

  return {
    id: "agents",
    title: "Agenten",
    status: failed > 0 || unknown > 0 ? "warn" : "ok",
    headline: String(running),
    subline: `von ${runtimes.length} eingerichteten Harnessen laufend`,
    lines,
    reason:
      failed > 0
        ? `${failed} Harness(e) im Fehlerzustand`
        : unknown > 0
          ? `${unknown} Harness(e) in einem dem Cockpit unbekannten Zustand`
          : null,
    hint: null,
  };
}

const RITUAL_LABELS: Record<string, string> = {
  morgenbrief: "Morgenbrief",
  "gate-batch": "Gate-Batch",
  "wochen-review": "Wochen-Review",
};

/**
 * When a ritual counts as overdue — twice its own cadence.
 *
 * Morning brief and gate batch run daily, the weekly review on Sundays. One
 * skipped run can be a laptop that was closed; two in a row means the schedule
 * is broken and nobody noticed, which is exactly what this tile is for.
 */
const RITUAL_OVERDUE_MS: Record<string, number> = {
  morgenbrief: 2 * 24 * 60 * 60 * 1000,
  "gate-batch": 2 * 24 * 60 * 60 * 1000,
  "wochen-review": 14 * 24 * 60 * 60 * 1000,
};

/** Tile (d): when each leadership ritual last actually ran. */
export function buildRitualsTile(
  envelope: SnapshotEnvelope,
  age: SnapshotAge,
): CockpitTile {
  const result = readBlock(envelope, "rituals");
  if (!result.ok) {
    return gapTile("rituals", "Rituale", result.reason, result.hint);
  }
  const last = asRecord(result.block.last_by_ritual);
  if (!last) {
    return gapTile(
      "rituals",
      "Rituale",
      "Keine Lauf-Quittungen — es ist UNBEKANNT, ob Rituale liefen (nicht: sie liefen nicht)",
      envelope.refreshHint,
    );
  }

  const now = Date.parse(envelope.readAt);
  let newest: number | null = null;
  let overdue = 0;
  let withGaps = 0;
  const lines: TileLine[] = Object.keys(RITUAL_LABELS).map((ritual) => {
    const entry = asRecord(last[ritual]);
    const at = entry ? asNonEmptyString(entry.at) : null;
    const parsed = at ? Date.parse(at) : Number.NaN;
    if (!Number.isFinite(parsed)) {
      return {
        label: RITUAL_LABELS[ritual],
        value: "nie belegt",
        emphasis: true,
      };
    }
    if (newest === null || parsed > newest) newest = parsed;
    const since = Math.max(0, now - parsed);
    const isOverdue = since > (RITUAL_OVERDUE_MS[ritual] ?? Infinity);
    if (isOverdue) overdue += 1;
    const exitCode = entry ? asFiniteNumber(entry.exit_code) : null;
    const gaps = entry ? asFiniteNumber(entry.gaps) : null;
    // exit 1 means the ritual ran but named gaps in its own data — that is
    // information, not noise, and it belongs on the tile.
    if (exitCode !== null && exitCode !== 0) withGaps += 1;
    const suffix =
      exitCode !== null && exitCode !== 0
        ? ` · exit ${exitCode}${gaps ? `, ${gaps} Lücke(n)` : ""}`
        : "";
    return {
      label: RITUAL_LABELS[ritual],
      value: `${formatAge(since)}${suffix}${isOverdue ? " · überfällig" : ""}`,
      emphasis: isOverdue || (exitCode !== null && exitCode !== 0),
    };
  });

  const missing = lines.filter((line) => line.value === "nie belegt").length;
  const partial = asNonEmptyString(result.block.reason);
  const trouble = [
    missing > 0
      ? `${missing} Ritual(e) ohne jede Quittung — Status unbekannt`
      : null,
    overdue > 0 ? `${overdue} Ritual(e) überfällig` : null,
    withGaps > 0 ? `${withGaps} Lauf(e) mit benannten Lücken beendet` : null,
    partial,
  ].filter((entry): entry is string => entry !== null);

  return {
    id: "rituals",
    title: "Rituale",
    status: age.stale || trouble.length > 0 ? "warn" : "ok",
    headline:
      newest === null ? null : formatAge(Math.max(0, now - (newest as number))),
    subline:
      newest === null
        ? "kein Ritual belegt"
        : `letzter belegter Lauf · ${Object.keys(RITUAL_LABELS).length - missing}/${Object.keys(RITUAL_LABELS).length} Rituale mit Quittung`,
    lines,
    reason: age.stale ? staleNote(age) : trouble.join(" · ") || null,
    hint: newest === null ? envelope.refreshHint : null,
  };
}

export function buildCockpitTiles(
  envelope: SnapshotEnvelope,
  agents: AgentRuntimeSource,
): CockpitTile[] {
  const age = snapshotAge(envelope);
  return [
    buildGatesTile(envelope, age),
    buildBacklogTile(envelope, age),
    buildAgentsTile(agents),
    buildRitualsTile(envelope, age),
  ];
}
