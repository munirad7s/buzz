import assert from "node:assert/strict";
import test from "node:test";

import {
  buildAgentsTile,
  buildBacklogTile,
  buildCockpitTiles,
  buildGatesTile,
  buildRitualsTile,
  formatAge,
  snapshotAge,
  STALE_AFTER_MS,
} from "./cockpitModel.ts";

const READ_AT = "2026-08-01T18:00:00Z";
const FRESH = "2026-08-01T17:55:00Z";
const ANCIENT = "2026-07-30T09:00:00Z";

function envelope(overrides = {}) {
  return {
    path: "C:/Users/x/.buzz/cockpit.json",
    snapshot: {
      schema_version: 1,
      generated_at: FRESH,
      backlog: {
        state: "ok",
        repos_read: 28,
        repos_expected: 28,
        ready_total: 383,
        by_prio: { "P1-money": 0, P1: 65, P2: 250, P3: 60, ohne: 8 },
        in_progress: 10,
        blocked: 92,
        top_blocked: [
          {
            repo: "munirad7s/agency-infra",
            number: 7,
            title: "[GATE] LetterXpress-Konto anlegen",
            url: "https://github.com/munirad7s/agency-infra/issues/7",
            prio: "P1-money",
          },
        ],
        reason: null,
      },
      rituals: {
        state: "ok",
        last_by_ritual: {
          morgenbrief: {
            at: "2026-08-01T08:45:00+0200",
            exit_code: 0,
            gaps: 0,
          },
          "gate-batch": {
            at: "2026-07-31T20:45:00+0200",
            exit_code: 1,
            gaps: 2,
          },
          "wochen-review": {
            at: "2026-07-27T18:00:00+0200",
            exit_code: 0,
            gaps: 0,
          },
        },
      },
    },
    readError: null,
    fileModifiedAt: FRESH,
    readAt: READ_AT,
    refreshHint: 'bash "C:/Users/x/.buzz/cockpit-snapshot.sh"',
    ...overrides,
  };
}

const age = (env) => snapshotAge(env);

// ---------------------------------------------------------------- happy path

test("gates tile reports the measured number and the top gate", () => {
  const env = envelope();
  const tile = buildGatesTile(env, age(env));

  assert.equal(tile.headline, "92");
  assert.equal(tile.status, "warn"); // 92 open gates is not a green state
  assert.equal(tile.lines.length, 1);
  assert.match(tile.lines[0].label, /P1-money · munirad7s\/agency-infra#7/);
  assert.equal(tile.lines[0].emphasis, true);
});

test("backlog tile lists every priority and the repo coverage", () => {
  const env = envelope();
  const tile = buildBacklogTile(env, age(env));

  assert.equal(tile.headline, "383");
  assert.equal(tile.status, "ok");
  assert.equal(tile.subline, "aus 28/28 Repos");
  assert.deepEqual(
    tile.lines.map((l) => `${l.label}=${l.value}`),
    ["P1-money=0", "P1=65", "P2=250", "P3=60", "ohne=8", "in-progress=10"],
  );
});

test("rituals tile ages every ritual from its receipt", () => {
  const env = envelope();
  const tile = buildRitualsTile(env, age(env));

  assert.equal(tile.status, "warn"); // gate-batch exited 1 with gaps
  assert.equal(tile.lines.length, 3);
  assert.match(tile.lines[0].value, /^vor /);
  assert.match(tile.lines[1].value, /exit 1, 2 Lücke\(n\)/);
});

// ------------------------------------------------- the rule: gaps, not zeros

test("missing snapshot file becomes a gap in every snapshot-backed tile", () => {
  const env = envelope({
    snapshot: null,
    readError:
      "kein Snapshot vorhanden (…/cockpit.json) — der Sammler lief hier noch nie",
    fileModifiedAt: null,
  });

  for (const tile of [
    buildGatesTile(env, age(env)),
    buildBacklogTile(env, age(env)),
    buildRitualsTile(env, age(env)),
  ]) {
    assert.equal(tile.status, "gap", `${tile.id} must be a gap`);
    assert.equal(tile.headline, null, `${tile.id} must not invent a number`);
    assert.equal(tile.subline, "nicht erhoben");
    assert.match(tile.reason, /kein Snapshot vorhanden/);
    assert.ok(tile.hint, `${tile.id} must say how to fix it`);
  }
});

test("a block that declares itself dead never becomes 0", () => {
  const env = envelope();
  env.snapshot.rituals = {
    state: "error",
    reason:
      "keine Lauf-Quittungen gefunden — es ist UNBEKANNT, ob Rituale liefen",
    last_by_ritual: null,
  };
  const tile = buildRitualsTile(env, age(env));

  assert.equal(tile.status, "gap");
  assert.equal(tile.headline, null);
  assert.match(tile.reason, /UNBEKANNT/);
});

test("gates: a missing `blocked` field is unknown, not zero", () => {
  const env = envelope();
  delete env.snapshot.backlog.blocked;
  const tile = buildGatesTile(env, age(env));

  assert.equal(tile.status, "gap");
  assert.equal(tile.headline, null);
  assert.match(tile.reason, /UNBEKANNT \(nicht 0\)/);
});

test("gates: a real measured zero is allowed to say so", () => {
  const env = envelope();
  env.snapshot.backlog.blocked = 0;
  env.snapshot.backlog.top_blocked = [];
  const tile = buildGatesTile(env, age(env));

  assert.equal(tile.status, "ok");
  assert.equal(tile.headline, "0");
  assert.match(tile.subline, /gemessen, nicht angenommen/);
});

test("backlog: a priority the collector omitted shows as not-collected", () => {
  const env = envelope();
  delete env.snapshot.backlog.by_prio["P1-money"];
  const tile = buildBacklogTile(env, age(env));

  const line = tile.lines.find((l) => l.label === "P1-money");
  assert.equal(line.value, "nicht erhoben");
});

test("backlog: partial repo coverage marks the total as a floor", () => {
  const env = envelope();
  env.snapshot.backlog.repos_read = 20;
  env.snapshot.backlog.state = "warn";
  const tile = buildBacklogTile(env, age(env));

  assert.equal(tile.status, "warn");
  assert.match(tile.reason, /Untergrenze/);
});

test("an unknown schema version refuses to interpret the numbers", () => {
  const env = envelope();
  env.snapshot.schema_version = 99;
  const tile = buildBacklogTile(env, age(env));

  assert.equal(tile.status, "gap");
  assert.equal(tile.headline, null);
  assert.match(tile.reason, /Schema 99/);
});

test("a JSON array masquerading as a snapshot is refused", () => {
  const env = envelope({ snapshot: [1, 2, 3] });
  const tile = buildGatesTile(env, age(env));

  assert.equal(tile.status, "gap");
  assert.equal(tile.headline, null);
});

// -------------------------------------------------------------- staleness

test("a stale snapshot keeps its number but is flagged", () => {
  const env = envelope({ fileModifiedAt: ANCIENT });
  const a = age(env);

  assert.equal(a.stale, true);
  const tile = buildGatesTile(env, a);
  assert.equal(
    tile.headline,
    "92",
    "an old measurement is still a measurement",
  );
  assert.equal(tile.status, "warn");
  assert.match(tile.reason, /älter als 12 h/);
});

test("a snapshot without mtime counts as stale, not as fresh", () => {
  const env = envelope({ fileModifiedAt: null });
  const a = age(env);

  assert.equal(a.ms, null);
  assert.equal(a.stale, true, "unknown freshness must fail towards distrust");
  assert.equal(a.label, "Alter unbekannt");
});

test("the staleness threshold is the one the tests assume", () => {
  const env = envelope({
    fileModifiedAt: new Date(
      Date.parse(READ_AT) - STALE_AFTER_MS + 1000,
    ).toISOString(),
  });
  assert.equal(age(env).stale, false);

  const older = envelope({
    fileModifiedAt: new Date(
      Date.parse(READ_AT) - STALE_AFTER_MS - 1000,
    ).toISOString(),
  });
  assert.equal(age(older).stale, true);
});

// ----------------------------------------------------------------- agents

test("agents tile counts lifecycles and separates unknown states", () => {
  const tile = buildAgentsTile({
    state: "ok",
    runtimes: [
      { pubkey: "a", lifecycle: "ready" },
      { pubkey: "b", lifecycle: "listening" },
      { pubkey: "c", lifecycle: "failed", error: "boom" },
      { pubkey: "d", lifecycle: "stopped" },
      { pubkey: "e", lifecycle: "hibernating" },
    ],
  });

  assert.equal(tile.headline, "2");
  assert.equal(tile.status, "warn");
  const byLabel = Object.fromEntries(tile.lines.map((l) => [l.label, l.value]));
  assert.equal(byLabel.laufend, "2");
  assert.equal(byLabel.fehlerhaft, "1");
  assert.equal(byLabel.gestoppt, "1");
  assert.equal(byLabel["unbekannter Zustand"], "1");
});

test("agents tile: an unreachable runtime is a gap, not 0 agents", () => {
  const tile = buildAgentsTile({
    state: "error",
    message: "IPC nicht erreichbar",
  });

  assert.equal(tile.status, "gap");
  assert.equal(tile.headline, null);
  assert.match(tile.reason, /IPC nicht erreichbar/);
});

test("agents tile: genuinely zero configured harnesses reads as measured 0", () => {
  const tile = buildAgentsTile({ state: "ok", runtimes: [] });

  assert.equal(tile.headline, "0");
  assert.equal(tile.status, "ok");
  assert.match(tile.subline, /von 0 eingerichteten/);
});

// ------------------------------------------------------------------ misc

test("formatAge covers the ranges the tiles use", () => {
  assert.equal(formatAge(30_000), "gerade eben");
  assert.equal(formatAge(3 * 60_000), "vor 3 min");
  assert.equal(formatAge(2 * 3_600_000 + 5 * 60_000), "vor 2 h 5 min");
  assert.equal(formatAge(3 * 3_600_000), "vor 3 h");
  assert.equal(formatAge(50 * 3_600_000), "vor 2 Tagen");
  assert.equal(formatAge(Number.NaN), "unbekannt");
});

test("buildCockpitTiles always returns exactly the four v1 tiles", () => {
  const tiles = buildCockpitTiles(envelope(), { state: "ok", runtimes: [] });
  assert.deepEqual(
    tiles.map((t) => t.id),
    ["gates", "backlog", "agents", "rituals"],
  );

  const broken = buildCockpitTiles(
    envelope({ snapshot: null, readError: "kaputt", fileModifiedAt: null }),
    { state: "error", message: "tot" },
  );
  assert.deepEqual(
    broken.map((t) => t.status),
    ["gap", "gap", "gap", "gap"],
  );
  assert.ok(
    broken.every((t) => t.headline === null),
    "no tile may show a number when nothing was measured",
  );
});
