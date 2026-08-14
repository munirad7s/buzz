import { expect, test } from "@playwright/test";

import { installMockBridge } from "../helpers/bridge";

test.beforeEach(async ({ page }) => {
  await installMockBridge(page);
});

test("starts and stops a read-only voice briefing", async ({ page }) => {
  const pageErrors: Error[] = [];
  page.on("pageerror", (error) => pageErrors.push(error));
  await page.goto("/");
  await expect(page.getByTestId("app-sidebar")).toBeVisible();
  expect(pageErrors).toEqual([]);
  await page.evaluate(() => {
    class FakePeerConnection {
      ontrack: ((event: { streams: MediaStream[] }) => void) | null = null;
      addTrack() {}
      close() {}
      createDataChannel() {
        return { close() {}, onmessage: null };
      }
      async createOffer() {
        return { type: "offer", sdp: "v=0\r\no=buzz 0 0 IN IP4 127.0.0.1\r\n" };
      }
      async setLocalDescription() {}
      async setRemoteDescription() {}
    }
    Object.defineProperty(window, "RTCPeerConnection", {
      configurable: true,
      value: FakePeerConnection,
    });
    Object.defineProperty(navigator, "mediaDevices", {
      configurable: true,
      value: {
        getUserMedia: async () => ({
          getTracks: () => [{ stop() {} }],
        }),
      },
    });
  });
  await page.getByTestId("open-voice-view").click();

  await expect(page.getByRole("heading", { name: "Voice" })).toBeVisible();
  await expect(page.getByText("Read only")).toBeVisible();
  await page.getByRole("button", { name: "Voice starten" }).click();
  await expect(page.getByText("Ich höre zu")).toBeVisible({ timeout: 10_000 });
  expect(pageErrors).toEqual([]);
  await expect(page.getByText(/1 Lücke · vollständig/)).toBeVisible();
  await page.getByRole("button", { name: "Stoppen" }).click();
  await expect(page.getByText("Bereit für deinen Morgenbrief")).toBeVisible();

  const commands = await page.evaluate(
    () =>
      (window as Window & { __BUZZ_E2E_COMMANDS__?: string[] })
        .__BUZZ_E2E_COMMANDS__ ?? [],
  );
  expect(commands).toContain("voice_start");
  expect(commands).toContain("voice_stop");
  await page.screenshot({
    path: "test-results/voice-panel-live-proof.png",
    fullPage: true,
  });
});
