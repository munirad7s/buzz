# Buzz Voice Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a tested read-only `/voice` panel that negotiates Codex Realtime with the existing ChatGPT subscription and no paid API path.

**Architecture:** A process-backed Rust actor owns one `codex app-server` JSON-RPC session and exposes two Tauri commands. A 16-KiB read-only snapshot combines the local Empire cockpit with a direct authenticated relay query. The React route owns WebRTC, transcript state, cleanup, error classification, and the generated visual design language.

**Tech Stack:** Rust, Tokio, serde/serde_json, Tauri 2, React 19, TypeScript, WebRTC, TanStack Router, Node test runner, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-13-buzz-voice-panel-design.md`

## Global Constraints

- Never use `OPENAI_API_KEY`, a paid API fallback, an upgrade, or a billable hosted service.
- Use only the existing ChatGPT-subscription Codex login and voice `spruce`.
- Keep the feature read-only: no tools, relay writes, approvals, gates, deployments, Vault writes, or shell agents.
- Snapshot output is valid UTF-8 and at most 16 KiB, with missing sources represented as named gaps.
- Do not log SDP, snapshot content, credentials, signing keys, tokens, or secret-bearing environment values.
- Generate exactly ten new horizontal references through the built-in keyless image path before implementing frontend visuals.
- Work only in `feat/13-voice-panel`; preserve unrelated worktrees and changes.

---

### Task 1: Generate and document the ten no-cost visual references

**Files:**
- Create: `.empire/voice-visuals/01-idle.png` through `.empire/voice-visuals/10-narrow-laptop.png`
- Create: `.empire/voice-visuals/manifest.json`
- Create: `.empire/VOICE.md`

**Interfaces:**
- Consumes: the ten states and visual direction from the design spec.
- Produces: ten local PNG references and a manifest consumed by frontend implementation and documentation.

- [x] **Step 1: Generate one horizontal image per state**

Use the built-in keyless image-generation tool ten times with a shared prompt suffix: `ink graphite desktop application, warm amber signal, neutral Swiss typography, subtle noise gradient, asymmetric premium layout, no purple, no gradients behind text, 16:9 horizontal UI reference`. Prefix each prompt with the exact state: idle, microphone permission, connecting, listening, user transcript, assistant speaking, entitlement denied, quota unavailable, stale snapshot, narrow laptop.

- [x] **Step 2: Store and hash each generated original**

```powershell
Get-FileHash -Algorithm SHA256 .empire/voice-visuals/*.png | Sort-Object Path
```

Expected: exactly ten distinct PNG paths and ten non-empty SHA-256 hashes.

- [x] **Step 3: Write the manifest and documentation**

`manifest.json` must contain `schemaVersion: 1`, `generationPath: "built-in-keyless-imagegen"`, `cost: "no-user-spend"`, and ten objects with `index`, `state`, `file`, `prompt`, and lowercase `sha256`. `.empire/VOICE.md` must describe preflight, architecture, security boundary, local proof commands, and embed all ten relative images.

- [x] **Step 4: Verify the visual evidence contract**

```powershell
$manifest = Get-Content .empire/voice-visuals/manifest.json -Raw | ConvertFrom-Json
$manifest.references.Count
($manifest.references.file | Sort-Object -Unique).Count
```

Expected: `10` and `10`.

- [x] **Step 5: Commit and push**

```bash
git add .empire/VOICE.md .empire/voice-visuals
git commit -s -m "docs: establish voice visual language"
git push
```

### Task 2: Build the app-server protocol core test-first

**Files:**
- Create: `desktop/src-tauri/src/voice_assistant/mod.rs`
- Create: `desktop/src-tauri/src/voice_assistant/protocol.rs`
- Create: `desktop/src-tauri/src/voice_assistant/protocol_tests.rs`
- Modify: `desktop/src-tauri/src/lib.rs`

**Interfaces:**
- Consumes: newline-delimited JSON-RPC messages from `codex app-server`.
- Produces: `RpcRequestId`, `ServerMessage`, `RealtimeEvent`, `classify_server_message(Value)`, and sanitized `VoiceErrorKind` values.

- [ ] **Step 1: Write failing protocol tests**

```rust
#[test]
fn start_ack_is_not_an_sdp_answer() {
    assert_eq!(classify_server_message(json!({"id": 3, "result": {}})), ServerMessage::Response { id: 3, result: json!({}) });
}

#[test]
fn matching_sdp_notification_is_success_data() {
    let message = classify_server_message(json!({"method":"thread/realtime/sdp","params":{"threadId":"t-1","sdp":"answer"}}));
    assert_eq!(message, ServerMessage::RealtimeSdp { thread_id: "t-1".into(), sdp: "answer".into() });
}
```

- [ ] **Step 2: Run RED**

```bash
cargo test --manifest-path desktop/src-tauri/Cargo.toml voice_assistant::protocol_tests
```

Expected: FAIL because `voice_assistant` and parser types do not exist.

- [ ] **Step 3: Implement the minimum parser and error classifier**

Parse responses by numeric `id`; parse `thread/realtime/sdp` and `thread/realtime/error` notifications by `threadId`; reject malformed lines as `VoiceErrorKind::Protocol`; classify 403/login/quota text into stable UI codes without retaining raw credential-bearing text.

- [ ] **Step 4: Run GREEN and format**

```bash
cargo test --manifest-path desktop/src-tauri/Cargo.toml voice_assistant::protocol_tests
cargo fmt --manifest-path desktop/src-tauri/Cargo.toml --all -- --check
```

Expected: focused tests PASS and format check exits 0.

- [ ] **Step 5: Commit and push**

```bash
git add desktop/src-tauri/src/voice_assistant desktop/src-tauri/src/lib.rs
git commit -s -m "feat: define safe voice protocol"
git push
```

### Task 3: Implement the persistent Codex actor test-first

**Files:**
- Create: `desktop/src-tauri/src/voice_assistant/client.rs`
- Create: `desktop/src-tauri/src/voice_assistant/client_tests.rs`
- Modify: `desktop/src-tauri/src/voice_assistant/mod.rs`

**Interfaces:**
- Consumes: `CodexTransport` with async `send(Value)` and `recv()` methods, local SDP, instructions, and snapshot text.
- Produces: `VoiceClient::start(sdp, snapshot) -> Result<VoiceStartResponse, VoiceCommandError>` and `VoiceClient::stop(thread_id) -> Result<(), VoiceCommandError>`.

- [ ] **Step 1: Write scripted-transport lifecycle tests**

Cover initialize, `thread/start`, `thread/realtime/start`, acknowledgement before SDP, matching error, timeout, process exit, wrong-thread notification, and idempotent stop. Assert the thread request contains `approvalPolicy: "never"`, `sandbox: "read-only"`, no tools, voice `spruce`, and the supplied snapshot only inside initial instructions.

- [ ] **Step 2: Run RED**

```bash
cargo test --manifest-path desktop/src-tauri/Cargo.toml voice_assistant::client_tests
```

Expected: FAIL because `VoiceClient` and `CodexTransport` do not exist.

- [ ] **Step 3: Implement actor and production process transport**

Spawn `codex app-server --stdio --enable realtime_conversation` with piped stdin/stdout, null stderr, `OPENAI_API_KEY` removed, and `CREATE_NO_WINDOW` on Windows. Initialize once, serialize writes, route responses by ID, wait up to 30 seconds for matching SDP, and kill/reap the child on protocol failure or drop.

- [ ] **Step 4: Run GREEN and focused clippy**

```bash
cargo test --manifest-path desktop/src-tauri/Cargo.toml voice_assistant::client_tests
cargo clippy --manifest-path desktop/src-tauri/Cargo.toml --lib -- -D warnings
```

Expected: lifecycle tests PASS; no branch-caused warning in the new module.

- [ ] **Step 5: Commit and push**

```bash
git add desktop/src-tauri/src/voice_assistant
git commit -s -m "feat: negotiate Codex realtime safely"
git push
```

### Task 4: Build the bounded read-only snapshot and Tauri commands

**Files:**
- Create: `desktop/src-tauri/src/voice_assistant/snapshot.rs`
- Create: `desktop/src-tauri/src/voice_assistant/snapshot_tests.rs`
- Create: `desktop/src-tauri/src/voice_assistant/commands.rs`
- Create: `desktop/src-tauri/src/voice_assistant/commands_tests.rs`
- Modify: `desktop/src-tauri/src/commands/empire_cockpit.rs`
- Modify: `desktop/src-tauri/src/lib.rs`

**Interfaces:**
- Consumes: reusable cockpit envelope loader, `query_relay(&AppState, filters)`, and `VoiceClient`.
- Produces: `build_voice_snapshot(&AppState) -> VoiceSnapshot`, `voice_start`, `voice_stop`, and managed `VoiceAssistantState`.

- [ ] **Step 1: Write failing snapshot and command tests**

Test complete and partial sources, missing cockpit, relay failure, named gaps, stable ordering, UTF-8 input crossing 16 KiB, exact byte ceiling, fake-client start/stop forwarding, blank SDP rejection, and mismatched thread stop rejection.

- [ ] **Step 2: Run RED**

```bash
cargo test --manifest-path desktop/src-tauri/Cargo.toml voice_assistant::snapshot_tests voice_assistant::commands_tests
```

Expected: FAIL because snapshot builder and commands do not exist.

- [ ] **Step 3: Implement the snapshot and commands**

Expose a crate-private cockpit read helper, query only recent text events needed for a concise feed excerpt, sanitize and serialize selected fields, append named gaps, and truncate on a UTF-8 boundary to `16 * 1024` bytes. Register `VoiceAssistantState`, `voice_start`, and `voice_stop` in `lib.rs` without expanding command responsibilities elsewhere.

- [ ] **Step 4: Run GREEN and Rust gates**

```bash
cargo test --manifest-path desktop/src-tauri/Cargo.toml voice_assistant
cargo fmt --manifest-path desktop/src-tauri/Cargo.toml --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
```

Expected: focused voice tests PASS; supported workspace clippy exits 0.

- [ ] **Step 5: Commit and push**

```bash
git add desktop/src-tauri/src/voice_assistant desktop/src-tauri/src/commands/empire_cockpit.rs desktop/src-tauri/src/lib.rs
git commit -s -m "feat: expose read-only voice commands"
git push
```

### Task 5: Implement the WebRTC session library test-first

**Files:**
- Create: `desktop/src/features/voice/lib/voiceSession.ts`
- Create: `desktop/src/features/voice/lib/voiceSession.test.mjs`
- Create: `desktop/src/features/voice/lib/voiceModel.ts`
- Create: `desktop/src/features/voice/lib/voiceModel.test.mjs`
- Create: `desktop/src/shared/api/tauriVoice.ts`

**Interfaces:**
- Consumes: `navigator.mediaDevices`, `RTCPeerConnection`, and Tauri `voice_start`/`voice_stop`.
- Produces: `createVoiceSession(callbacks)`, `normalizeRealtimeEvent(value)`, `classifyVoiceError(error)`, and typed Tauri wrappers.

- [ ] **Step 1: Write failing frontend unit tests**

Assert mono/echo-cancellation/noise-suppression constraints, SDP invocation payload, remote answer application, transcript variants, partial-start cleanup, stop invocation, 45-second inactivity cleanup, and distinct login/403/quota/permission/protocol labels.

- [ ] **Step 2: Run RED**

```bash
cd desktop && pnpm test -- --test-name-pattern="voice"
```

Expected: FAIL because voice modules do not exist.

- [ ] **Step 3: Implement the minimal session and pure model**

Create the data channel before the offer, attach local tracks, add a hidden remote `Audio` element, normalize transcript deltas/completions, reset the inactivity timer on meaningful events, and make cleanup idempotent across every partial state.

- [ ] **Step 4: Run GREEN and checks**

```bash
cd desktop && pnpm test -- --test-name-pattern="voice" && pnpm typecheck && pnpm check
```

Expected: voice tests PASS and all desktop checks exit 0 apart from already documented informational Biome hints outside changed files.

- [ ] **Step 5: Commit and push**

```bash
git add desktop/src/features/voice/lib desktop/src/shared/api/tauriVoice.ts
git commit -s -m "feat: manage voice WebRTC lifecycle"
git push
```

### Task 6: Build the `/voice` route and visual state surface

**Files:**
- Create: `desktop/src/features/voice/ui/VoicePanelScreen.tsx`
- Create: `desktop/src/features/voice/ui/VoicePanelScreen.test.mjs`
- Create: `desktop/src/app/routes/voice.tsx`
- Modify: `desktop/src/app/routes.ts`
- Modify: `desktop/src/features/sidebar/ui/AppSidebarPinnedHeader.tsx`
- Modify: `preview-features.json`
- Regenerate: `desktop/src/app/routeTree.gen.ts`

**Interfaces:**
- Consumes: `createVoiceSession`, generated visual references, preview feature gate, and router.
- Produces: navigable `/voice` preview route with idle, permission, connecting, listening, speaking, stopping, and error views.

- [ ] **Step 1: Write failing model/surface assertions**

Test idle start control, disabled connecting state, active stop control, elapsed timer, user/assistant transcript excerpts, snapshot gaps, error recovery, route registration, sidebar active state, keyboard focus, and accessible status announcements.

- [ ] **Step 2: Run RED**

```bash
cd desktop && pnpm test -- --test-name-pattern="VoicePanel|voice route"
```

Expected: FAIL because route and screen do not exist.

- [ ] **Step 3: Implement the screen from the visual set**

Use an ink/graphite page, subtle CSS noise, warm amber active border glow, restrained cards, a large magnetic-feeling microphone button with reduced-motion fallback, responsive asymmetric columns, semantic buttons, `aria-live`, and no purple or decorative pill clutter.

- [ ] **Step 4: Regenerate routes and run GREEN**

```bash
cd desktop && pnpm build && pnpm test -- --test-name-pattern="VoicePanel|voice route" && pnpm check
```

Expected: generated tree includes `/voice`; tests, build, and checks PASS.

- [ ] **Step 5: Commit and push**

```bash
git add desktop/src/features/voice desktop/src/app/routes/voice.tsx desktop/src/app/routes.ts desktop/src/app/routeTree.gen.ts desktop/src/features/sidebar/ui/AppSidebarPinnedHeader.tsx preview-features.json
git commit -s -m "feat: add voice command surface"
git push
```

### Task 7: Add deterministic E2E and local live proof

**Files:**
- Modify: `desktop/src/testing/e2eBridge.ts`
- Create: `desktop/tests/e2e/voice-panel.spec.ts`
- Modify: `.empire/VOICE.md`

**Interfaces:**
- Consumes: `/voice`, Tauri bridge commands, browser media/WebRTC mocks, and the live local app-server.
- Produces: screenshot/state proof plus recorded local no-key negotiation evidence.

- [ ] **Step 1: Add bridge fixtures and E2E states**

Mock `voice_start` with `{ threadId: "voice-e2e", sdpAnswer: validFixture }`, record `voice_stop`, stub microphone permission, and prove idle, connecting, listening, entitlement-error, quota-error, stale-snapshot, and narrow-laptop layouts.

- [ ] **Step 2: Run focused E2E**

```bash
cd desktop && pnpm exec playwright test tests/e2e/voice-panel.spec.ts --project=smoke
```

Expected: focused E2E PASS and screenshots show the generated design language.

- [ ] **Step 3: Run the live no-key probe and local Tauri launch**

```powershell
$env:OPENAI_API_KEY = $null
codex login status
pnpm --dir desktop tauri dev
```

Expected: ChatGPT login, `/voice` renders, and a start/stop session reaches an SDP answer. If microphone automation is unavailable, record that exact hardware boundary while retaining the real SDP notification and deterministic browser proof.

- [ ] **Step 4: Update `.empire/VOICE.md` with exact evidence**

Record commands, timestamps in Europe/Berlin, result counts, visual manifest hash, live thread ID prefix only, and any physical microphone boundary. Do not record SDP or secrets.

- [ ] **Step 5: Commit and push**

```bash
git add desktop/src/testing/e2eBridge.ts desktop/tests/e2e/voice-panel.spec.ts .empire/VOICE.md
git commit -s -m "test: prove voice panel locally"
git push
```

### Task 8: Verify, review, merge, close, and journal

**Files:**
- Modify if findings require: only branch-owned files from Tasks 1-7
- Update outside Git: Vault project note, repository note, and `01 Journal/2026-08/2026-08-13.md`

**Interfaces:**
- Consumes: complete branch and local proof.
- Produces: merged PR, closed #13, clean worktree, and shared-memory evidence.

- [ ] **Step 1: Run exact local parity**

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --manifest-path desktop/src-tauri/Cargo.toml --all -- --check
cd desktop && pnpm test && pnpm check && pnpm typecheck
cd ../web && pnpm check
cd .. && just test-unit
git diff --check origin/main...HEAD
```

Expected: all supported gates PASS; only the pre-existing whole-Tauri Windows clippy exception documented in `.empire/BUILD.md` may remain, with no new-file warning.

- [ ] **Step 2: Review the full diff and fix findings**

Inspect for API keys or paid fallback, relay writes, tools, raw SDP/snapshot logs, child leaks, UTF-8 overflow, false-zero gaps, inaccessible controls, unrelated files, and missing visual references. Re-run affected RED/GREEN and parity checks after every fix.

- [ ] **Step 3: Create and verify the PR**

```bash
gh pr create --repo munirad7s/buzz --base main --head feat/13-voice-panel --title "feat: add no-cost read-only voice panel" --body-file .empire/voice-pr-body.md
gh pr checks --watch
```

Expected: PR exists and all available checks are successful, or hosted zero-step billing is explicitly replaced by exact local parity evidence.

- [ ] **Step 4: Squash-merge and close issue with evidence**

```bash
gh pr merge --squash --delete-branch
gh issue comment 13 --repo munirad7s/buzz --body-file .empire/voice-issue-evidence.md
gh issue close 13 --repo munirad7s/buzz
```

Expected: PR state `MERGED`, `origin/main` contains the merge SHA, and issue #13 state is `CLOSED`.

- [ ] **Step 5: Update and verify the Vault**

Update `03 Projects/buzz-command-center.md`, `07 Repositories/munirad7s-buzz.md`, and append 3-8 bullets to today's journal. Read all three updates back. Never commit or manually push the Vault.
