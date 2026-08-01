// .empire/tools/mcp-call.mjs — ein MCP-Tool headless aus einem Script aufrufen (buzz#10)
//
// Die Fuehrungsrituale brauchen echte Daten aus Quellen, die nur als MCP-Server
// existieren (Gmail via google-mcp, Telegram via telegram-mcp, CRM via espo-mcp).
// Ein Shell-Script kann kein MCP sprechen — dieser Adapter schon.
//
// Server-Definitionen kommen aus dem Nest (`~/.buzz/.mcp.json`), damit es genau
// EINE Quelle fuer Kommandos/Pfade gibt (Entscheid buzz#4).
//
//   node mcp-call.mjs --server google-mcp --tool gmail_search \
//        --args '{"query":"is:unread newer_than:1d","maxResults":25}'
//   node mcp-call.mjs --server google-mcp --list
//
// Exit-Codes: 0 = Ergebnis auf stdout · 2 = Server/Handshake tot · 3 = Tool-Fehler
// Fehler gehen NIE als leeres Ergebnis durch — der Aufrufer soll die Luecke sehen.
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// Das MCP-SDK liegt in den node_modules der MCP-Server, nicht in diesem Repo
// (kein eigenes package.json im Fork). ESM ignoriert NODE_PATH, deshalb wird
// der Pfad explizit aufgeloest — kein npm install im Buzz-Fork noetig.
const SDK_HOMES = (
  process.env.MCP_SDK_HOME ?? "C:/Users/rescue/mcp-servers/google-mcp"
).split(";");
const sdkBase = SDK_HOMES.map((h) => join(h, "node_modules", "@modelcontextprotocol", "sdk")).find(
  (p) => existsSync(p),
);
if (!sdkBase) {
  console.error(`mcp-call: MCP-SDK nicht gefunden (gesucht in: ${SDK_HOMES.join(", ")})`);
  process.exit(2);
}
const { Client } = await import(pathToFileURL(join(sdkBase, "dist", "esm", "client", "index.js")));
const { StdioClientTransport } = await import(
  pathToFileURL(join(sdkBase, "dist", "esm", "client", "stdio.js"))
);

const argv = process.argv.slice(2);
const opt = (n, d = null) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 && argv[i + 1] !== undefined ? argv[i + 1] : d;
};
const flag = (n) => argv.includes(`--${n}`);

const serverName = opt("server");
const toolName = opt("tool");
const rawArgs = opt("args", "{}");
const timeoutMs = Number(opt("timeout", "60000"));
const configPath = opt("config", join(homedir(), ".buzz", ".mcp.json"));

if (!serverName || (!toolName && !flag("list"))) {
  console.error("usage: mcp-call.mjs --server <name> (--tool <tool> --args '<json>' | --list)");
  process.exit(64);
}

let cfg;
try {
  cfg = JSON.parse(readFileSync(configPath, "utf-8"));
} catch (e) {
  console.error(`mcp-call: Konfiguration nicht lesbar (${configPath}): ${e.message}`);
  process.exit(2);
}
const def = cfg?.mcpServers?.[serverName];
if (!def) {
  console.error(`mcp-call: Server '${serverName}' steht nicht in ${configPath}`);
  process.exit(2);
}

let toolArgs;
try {
  toolArgs = JSON.parse(rawArgs);
} catch (e) {
  console.error(`mcp-call: --args ist kein JSON: ${e.message}`);
  process.exit(64);
}

const client = new Client({ name: "empire-ritual", version: "1.0.0" });
const kill = setTimeout(() => {
  console.error(`mcp-call: Timeout nach ${timeoutMs} ms (${serverName}/${toolName ?? "list"})`);
  process.exit(2);
}, timeoutMs);

try {
  await client.connect(
    new StdioClientTransport({
      command: def.command,
      args: def.args ?? [],
      env: { ...process.env, ...(def.env ?? {}) },
      stderr: "ignore",
    }),
  );
} catch (e) {
  clearTimeout(kill);
  console.error(`mcp-call: Handshake mit '${serverName}' fehlgeschlagen: ${e.message}`);
  process.exit(2);
}

if (flag("list")) {
  const tools = (await client.listTools()).tools.map((t) => t.name).sort();
  console.log(JSON.stringify(tools));
  clearTimeout(kill);
  process.exit(0);
}

let res;
try {
  res = await client.callTool({ name: toolName, arguments: toolArgs });
} catch (e) {
  clearTimeout(kill);
  console.error(`mcp-call: Tool '${toolName}' fehlgeschlagen: ${e.message}`);
  process.exit(3);
}
clearTimeout(kill);

// isError bedeutet: das Tool hat geantwortet, aber negativ. Das ist ein Fehler,
// kein leeres Ergebnis — sonst landet es als stille Null im Brief.
if (res.isError) {
  console.error(`mcp-call: Tool '${toolName}' meldet Fehler: ${res.content?.[0]?.text ?? "?"}`);
  process.exit(3);
}
console.log(res.content?.map((c) => c.text ?? "").join("\n") ?? "");
process.exit(0);
