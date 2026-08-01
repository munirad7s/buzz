#!/usr/bin/env node
// mcp-env-shim.js — startet einen stdio-MCP-Server mit genau den Secrets, die er braucht.
//
// Warum: der Nest (`~/.buzz/.mcp.json`) ist die Wiederherstellungsquelle im OEFFENTLICHEN Fork.
// Kein API-Key darf darin stehen. Der Shim holt die Keys zur Laufzeit aus `~/.secrets/master.env`
// und reicht ausschliesslich die per --keys benannten weiter (Allowlist, kein Vollexport).
//
//   node mcp-env-shim.js --keys N8N_API_URL,N8N_API_KEY -- <command> [args...]
//
// stdin/stdout/stderr werden durchgereicht (stdio-Transport bleibt unberuehrt),
// Exit-Code und Signale des Kindes werden weitergegeben.

const { spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const argv = process.argv.slice(2);
const sep = argv.indexOf("--");
if (sep === -1) {
  console.error("mcp-env-shim: fehlendes '--' vor dem Zielkommando");
  process.exit(64);
}

const flags = argv.slice(0, sep);
const target = argv.slice(sep + 1);
if (target.length === 0) {
  console.error("mcp-env-shim: kein Zielkommando nach '--'");
  process.exit(64);
}

const keysFlag = flags.indexOf("--keys");
const wanted =
  keysFlag === -1
    ? []
    : (flags[keysFlag + 1] || "")
        .split(",")
        .map((k) => k.trim())
        .filter(Boolean);

const envFile =
  process.env.MCP_ENV_SHIM_FILE || path.join(os.homedir(), ".secrets", "master.env");

function parseEnvFile(file) {
  const out = {};
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (err) {
    console.error(`mcp-env-shim: ${file} nicht lesbar: ${err.message}`);
    process.exit(66);
  }
  for (const line of raw.split(/\r?\n/)) {
    const m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/.exec(line);
    if (!m) continue;
    let value = m[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length > 1) ||
      (value.startsWith("'") && value.endsWith("'") && value.length > 1)
    ) {
      value = value.slice(1, -1);
    }
    out[m[1]] = value;
  }
  return out;
}

const env = { ...process.env };
if (wanted.length > 0) {
  const parsed = parseEnvFile(envFile);
  const missing = [];
  for (const key of wanted) {
    // Bereits gesetzte Env-Variablen gewinnen (erlaubt Rot-Proben ohne Datei-Edit).
    if (process.env[key] !== undefined && process.env[key] !== "") continue;
    if (parsed[key] === undefined) {
      missing.push(key);
      continue;
    }
    env[key] = parsed[key];
  }
  if (missing.length > 0) {
    // Laut schreien statt still ohne Key starten — eine stille Null ist der schlimmere Fehlermodus.
    console.error(`mcp-env-shim: Schluessel fehlen in ${envFile}: ${missing.join(", ")}`);
    process.exit(65);
  }
}

const [cmd, ...args] = target;
const isBatch = /\.(cmd|bat)$/i.test(cmd);
const child = isBatch
  ? spawn(process.env.ComSpec || "cmd.exe", ["/d", "/s", "/c", cmd, ...args], {
      stdio: "inherit",
      env,
      windowsVerbatimArguments: false,
    })
  : spawn(cmd, args, { stdio: "inherit", env });

child.on("error", (err) => {
  console.error(`mcp-env-shim: Start von ${cmd} fehlgeschlagen: ${err.message}`);
  process.exit(127);
});
child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code === null ? 1 : code);
});
