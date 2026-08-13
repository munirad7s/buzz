import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("voice panel keeps the route, safety copy, accessibility and preview gate wired", async () => {
  const [screen, route, sidebar, features] = await Promise.all([
    readFile(new URL("./VoicePanelScreen.tsx", import.meta.url), "utf8"),
    readFile(new URL("../../../app/routes/voice.tsx", import.meta.url), "utf8"),
    readFile(
      new URL("../../sidebar/ui/AppSidebarPinnedHeader.tsx", import.meta.url),
      "utf8",
    ),
    readFile(
      new URL("../../../../../preview-features.json", import.meta.url),
      "utf8",
    ),
  ]);

  assert.match(route, /createFileRoute\("\/voice"\)/);
  assert.match(screen, /aria-live="polite"/);
  assert.match(screen, /Read only/);
  assert.match(screen, /snapshot\.gaps/);
  assert.match(screen, /useReducedMotion/);
  assert.match(sidebar, /voicePanel/);
  assert(
    JSON.parse(features).features.some(
      (feature) => feature.id === "voicePanel",
    ),
  );
});
