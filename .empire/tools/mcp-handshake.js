#!/usr/bin/env node
// mcp-handshake.js — startet EINEN stdio-MCP-Server aus einer .mcp.json und macht
// initialize + tools/list. Gibt "<toolcount>" oder "FEHLER:<grund>" auf stdout aus.
//
//   node mcp-handshake.js <pfad/zur/.mcp.json> <servername> [timeout-sekunden]
//
// Eigene Datei statt `node -e`, weil ein MEHRZEILIGES `node -e '…'` auf dieser Maschine
// (Git Bash + Volta-Shim) still NICHTS ausfuehrt — kein Fehler, keine Ausgabe, Exit 0.
// Gemessen in buzz#59; einzeilige `-e`-Programme laufen, mehrzeilige verschwinden.
const { spawn } = require("node:child_process");
const fs = require("node:fs");

const [cfgPath, serverName, timeoutArg] = process.argv.slice(2);
const timeoutMs = (Number(timeoutArg) || 60) * 1000;
const out = (msg) => { fs.writeSync(1, msg + "\n"); };

if (!cfgPath || !serverName) { out("FEHLER:usage"); process.exit(0); }

let cfg;
try {
  cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8")).mcpServers[serverName];
} catch (e) {
  out("FEHLER:config-" + e.code); process.exit(0);
}
if (!cfg) { out("FEHLER:kein-eintrag"); process.exit(0); }

const args = cfg.args || [];
const env = { ...process.env, ...(cfg.env || {}) };
const child = /\.(cmd|bat)$/i.test(cfg.command)
  ? spawn(process.env.ComSpec || "cmd.exe", ["/d", "/s", "/c", cfg.command, ...args], { stdio: ["pipe", "pipe", "pipe"], env })
  : spawn(cfg.command, args, { stdio: ["pipe", "pipe", "pipe"], env });

let buf = "", err = "", done = false;
const finish = (msg) => {
  if (done) return;
  done = true;
  out(msg);
  try { child.kill(); } catch {}
  process.exit(0);
};

child.stderr.on("data", (d) => { err += d.toString(); });
child.on("error", (e) => finish("FEHLER:spawn-" + (e.code || e.message)));
child.on("exit", (c) => finish("FEHLER:exit-" + c + (err ? "-" + err.trim().split("\n")[0].slice(0, 60) : "")));
child.stdout.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    let m;
    try { m = JSON.parse(line); } catch { continue; }
    if (m.id === 1) {
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }) + "\n");
    }
    if (m.id === 2) finish(String(((m.result || {}).tools || []).length));
  }
});

child.stdin.write(JSON.stringify({
  jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "nest-doctor", version: "1" } },
}) + "\n");

setTimeout(() => finish("FEHLER:timeout"), timeoutMs);
