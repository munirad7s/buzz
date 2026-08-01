// Legt EINEN Uptime-Kuma-Push-Monitor "sentry-liveness" an (buzz#77) — additiv,
// idempotent über den Monitornamen. Bestehende Monitore und die Statuspage
// werden nicht angefasst.
//
// Dieser Monitor ist der Wachhund über dem Dauer-Agenten "Sentry" auf adas-hetzner.
// Solange `.empire/tools/sentry-liveness-probe.sh` beweist, dass Sentry auf eine echte
// Mention antwortet, kommt ein Heartbeat. Bleibt er aus, ist der Agent stumm — und das
// ist der Zustand, den weder `systemctl is-active` noch das Log zeigen können.
//
// Warum das Script und nicht ein Klick in der UI: der Monitor ist Teil des
// Wächters, nicht Dekoration. Wer ihn versehentlich löscht, muss ihn exakt so
// wiederherstellen können — inklusive Intervall und Benachrichtigungen.
//
// Kuma hat keine REST-API zum Anlegen von Monitoren, nur Socket.IO. Muster
// übernommen von /opt/agency/monitoring/provision/kuma-add-funnel-e2e.mjs.
//
// Env: KUMA_URL (default http://kuma:3001), KUMA_ADMIN_USER, KUMA_ADMIN_PASSWORD,
//      KUMA_PUSH_SENTRY_LIVENESS_TOKEN (Push-Token, `openssl rand -hex 8`).
//
// Aufruf auf adas-hetzner (Wegwerf-Container, nutzt die node_modules des
// monitoring-Provision-Ordners — socket.io-client liegt dort schon):
//   cd /opt/agency/monitoring && set -a && . ./.env && set +a
//   docker run --rm --memory 128m --network monitoring_monitoring-internal \
//     -v /opt/agency/monitoring/provision:/app:ro \
//     -v /tmp/kuma-add-sentry-liveness.mjs:/app/kuma-add-sentry-liveness.mjs:ro \
//     -w /app -e KUMA_ADMIN_USER -e KUMA_ADMIN_PASSWORD -e KUMA_PUSH_SENTRY_LIVENESS_TOKEN \
//     node:22-alpine node kuma-add-sentry-liveness.mjs
import { io } from "socket.io-client";

const URL = process.env.KUMA_URL ?? "http://kuma:3001";
const USER = process.env.KUMA_ADMIN_USER;
const PASS = process.env.KUMA_ADMIN_PASSWORD;
const TOKEN = process.env.KUMA_PUSH_SENTRY_LIVENESS_TOKEN;
if (!USER || !PASS) {
  console.error("[kuma] KUMA_ADMIN_USER/KUMA_ADMIN_PASSWORD fehlen");
  process.exit(1);
}
if (!TOKEN) {
  console.error("[kuma] KUMA_PUSH_SENTRY_LIVENESS_TOKEN fehlt");
  process.exit(1);
}

// interval = maximale Sekunden zwischen zwei Pushes, bis Kuma DOWN meldet.
// Die Probe läuft alle 30 Minuten -> 7200 s (2 h) Toleranz. Bewusst NICHT knapp:
// jede Probe kostet einen echten LLM-Aufruf, und das freie Modell antwortet
// gelegentlich mit 429. Bei knapper Toleranz würde der Wächter Munir bei jedem
// Provider-Schluckauf wecken — und ein Wächter, dem man nicht glaubt, ist
// schlechter als keiner. 2 h heißt: drei aufeinanderfolgende Fehlschläge werden
// verziehen, echte Stille meldet sich noch am selben Tag.
//
// maxretries = 0 — Abweichung von den neun älteren Push-Monitoren, die alle
// maxretries=1 tragen. Gemessen am 2026-08-01 (adas-empire#79): ein
// `status=down`-Push auf einen Monitor mit maxretries=1 erzeugt einen Heartbeat
// mit status=2 (PENDING) und important=0 — es geht KEINE Benachrichtigung raus.
// Erst der nächste fällige Beat nach retryInterval macht daraus DOWN. Bei
// retryInterval == interval verdoppelt das die Zeit bis zum Alarm still.
// Die Toleranz gehört ins interval, nicht in einen unsichtbaren Retry.
//
// notificationIDList: 2 = telegram-adas-agency, 3 = mail-resend-munir — dieselbe
// Kombination wie alle bestehenden Push-Monitore.
const MONITOR = {
  name: "sentry-liveness",
  type: "push",
  interval: 7200,
  retryInterval: 7200,
  resendInterval: 0,
  maxretries: 0,
  timeout: 20,
  pushToken: TOKEN,
  notificationIDList: { 2: true, 3: true },
  ignoreTls: false,
  upsideDown: false,
  expiryNotification: false,
  maxredirects: 10,
  accepted_statuscodes: ["200-299"],
  dns_resolve_type: "A",
  dns_resolve_server: "1.1.1.1",
  proxyId: null,
  mqttUsername: "",
  mqttPassword: "",
  mqttTopic: "",
  mqttSuccessMessage: "",
  method: "GET",
  headers: null,
  body: null,
  httpBodyEncoding: "json",
  conditions: [],
  parent: null,
};

const fail = (msg, detail) => {
  console.error(`[kuma] FEHLER ${msg}:`, JSON.stringify(detail));
  process.exit(1);
};

const socket = io(URL, {});
const call = (ev, ...args) => new Promise((res) => socket.emit(ev, ...args, (r) => res(r)));
setTimeout(() => fail("timeout", "60s ohne Abschluss"), 60000).unref?.();

let connectErrors = 0;
socket.on("connect_error", (e) => {
  if (++connectErrors >= 5) fail("connect_error", e.message);
});
socket.on("connect", async () => {
  const login = await call("login", { username: USER, password: PASS, token: "" });
  if (!login.ok) fail("login", login);

  const listPromise = new Promise((res) => socket.once("monitorList", (l) => res(l)));
  await call("getMonitorList");
  const existing = Object.values((await listPromise) ?? {});
  const found = existing.find((m) => m.name === MONITOR.name);
  if (found) {
    const cur = await call("getMonitor", found.id);
    if (!cur.ok) fail("getMonitor", cur);
    // Nicht nur der Push-Token wird nachgezogen, sondern auch das Alarmverhalten.
    // Ein Monitor, dessen interval/maxretries jemand in der UI verstellt hat, ist
    // still stumm — genau der Fehlermodus, gegen den dieses Ticket gebaut wurde.
    const want = {
      pushToken: TOKEN,
      interval: MONITOR.interval,
      retryInterval: MONITOR.retryInterval,
      maxretries: MONITOR.maxretries,
      notificationIDList: MONITOR.notificationIDList,
    };
    const drift = Object.entries(want).filter(([k, v]) =>
      k === "notificationIDList"
        ? JSON.stringify(Object.keys(v).sort()) !==
          JSON.stringify(Object.keys(cur.monitor[k] ?? {}).filter((n) => cur.monitor[k][n]).sort())
        : cur.monitor[k] !== v,
    );
    if (drift.length) {
      const upd = await call("editMonitor", { ...cur.monitor, ...want });
      if (!upd.ok) fail("editMonitor", upd);
      console.log(
        `[kuma] push "sentry-liveness" existiert (id=${found.id}) — nachgezogen: ${drift
          .map(([k]) => k)
          .join(", ")}`,
      );
    } else {
      console.log(`[kuma] push "sentry-liveness" existiert (id=${found.id}) — Konfiguration ok`);
    }
    console.log(`MONITOR_ID=${found.id}`);
    process.exit(0);
  }
  const r = await call("add", MONITOR);
  if (!r.ok) fail("add", r);
  console.log(`[kuma] push "sentry-liveness" angelegt (id=${r.monitorID})`);
  console.log(`MONITOR_ID=${r.monitorID}`);
  process.exit(0);
});
