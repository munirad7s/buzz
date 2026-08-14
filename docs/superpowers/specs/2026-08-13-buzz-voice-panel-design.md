# Buzz Voice Panel Design

## Goal

Add a read-only `/voice` experience to Buzz that negotiates OpenAI Realtime through `codex app-server` using Munir's existing ChatGPT subscription login. The feature must not use an OpenAI API key, paid API fallback, upgrade, hosted billable service, or mutating Buzz capability.

## Preconditions and Delivery Boundary

- GitHub issue #2 is closed.
- Issue #14 describes follow-up Voice-State-Tools work and is not a prerequisite for this read-only panel.
- The actual OAuth prerequisite, issue #18, is closed.
- `codex login status` reports a ChatGPT login while `OPENAI_API_KEY` is absent.
- A live no-key `codex app-server --enable realtime_conversation` probe has returned a `thread/realtime/sdp` notification for voice `spruce` without a 403 or quota error.
- Work stays in `feat/13-voice-panel`; unrelated worktrees and the dirty primary checkout remain untouched.
- The upstream merge ritual was attempted and aborted cleanly after four conflicts. With 231 upstream-only and 80 fork-only commits, absorbing that divergence would make this feature PR unsafe and unrelated.

## Architecture

`desktop/src-tauri/src/voice_assistant/` owns one process-backed actor. It starts `codex app-server --stdio --enable realtime_conversation`, sends newline-delimited JSON-RPC, initializes the server, creates an ephemeral read-only thread, negotiates a Realtime session, and serializes access from concurrent Tauri commands.

The actor treats the immediate `thread/realtime/start` result `{}` only as acknowledgement. A start succeeds only when the matching `thread/realtime/sdp` notification arrives. A matching `thread/realtime/error`, process exit, malformed protocol message, or timeout becomes a sanitized typed error. Stop sends `thread/realtime/stop`, unsubscribes the thread, and clears local state idempotently.

The frontend owns WebRTC media. It captures one mono microphone stream with echo cancellation and noise suppression, creates an `RTCPeerConnection`, opens the `oai-events` data channel, sends the local SDP through `voice_start`, applies the SDP answer, and plays remote audio. Stopping closes tracks, channels, peer connection, and the app-server session even when setup fails partway through.

## Rust Interfaces

The module exposes serializable command contracts:

```rust
pub struct VoiceStartResponse {
    pub thread_id: String,
    pub sdp_answer: String,
}

pub struct VoiceSnapshot {
    pub generated_at: String,
    pub content: String,
    pub truncated: bool,
    pub gaps: Vec<String>,
}

#[tauri::command]
pub async fn voice_start(
    state: State<'_, AppState>,
    voice: State<'_, VoiceAssistantState>,
    sdp: String,
) -> Result<VoiceStartResponse, VoiceCommandError>;

#[tauri::command]
pub async fn voice_stop(
    voice: State<'_, VoiceAssistantState>,
    thread_id: String,
) -> Result<(), VoiceCommandError>;
```

`VoiceAssistantState` wraps the actor in an async mutex and is registered once by the Tauri builder. Only one active Realtime session is supported because the product surface exposes one microphone session.

The app-server client uses monotonically increasing request IDs and explicit pending-request ownership. Tests exercise parsing and lifecycle against scripted stdin/stdout fixtures without requiring a live Codex login.

## Read-Only Snapshot

Before thread creation, `voice_start` builds at most 16 KiB of UTF-8 context from:

1. the existing local Empire cockpit snapshot contract;
2. a direct authenticated read-only relay query using the current Buzz identity;
3. concise metadata describing missing, stale, or unavailable sources.

The snapshot never invokes a shell agent, sends a relay event, changes a gate, writes the Vault, or exposes signing keys, auth tokens, environment values, raw configuration, or hidden filesystem paths. Each source fails independently. Available context is retained and a `gaps` list records unavailable sources instead of converting a partial snapshot into a false all-clear. Truncation preserves valid UTF-8 and reserves room for the gaps section.

The Realtime thread instructions state that the assistant may summarize and discuss only the supplied snapshot and conversation. No tools are attached. Requests for approval, sending, writing, deployment, or mutation must be refused and redirected to the existing gated Buzz workflows.

## Frontend Experience

The `/voice` route is a preview feature and appears in the pinned sidebar near the Empire cockpit. It uses a small explicit state machine:

```text
idle -> requestingPermission -> connecting -> listening <-> speaking
                                      |             |
                                      +-> stopping <-+
any active state -> error -> idle
```

The page shows connection state, elapsed time, user and assistant transcript excerpts, snapshot freshness/gaps, and one dominant microphone/stop control. Transcript variants from the Realtime data channel are normalized before rendering. A 45-second no-activity timer stops the session locally.

Errors remain actionable and distinct:

- microphone permission denied;
- Codex not logged in;
- Realtime entitlement denied (403);
- quota unavailable;
- app-server unavailable or malformed;
- snapshot partially or wholly unavailable;
- WebRTC negotiation failed.

No message implies that a missing snapshot source is healthy. Technical details are sanitized for UI display and logs never include SDP, auth material, or snapshot content.

## Visual Direction and Reimagen Evidence

The interface uses an ink/graphite ground, warm amber signal color, neutral typography, restrained technical texture, and asymmetric spacing. It adapts four existing local component-gallery ideas without copying bundle code: simple Card structure, Border Glow around the active voice surface, Magnetic behavior for the primary microphone control, and a subtle Noise Gradient background.

Before frontend implementation, generate exactly ten new horizontal reference images through the built-in keyless image-generation path. No CLI or provider requiring `OPENAI_API_KEY` may be used. If that path becomes unavailable or requests spend, generation stops and the exact no-cost blocker is documented instead of falling back to a paid service.

The ten references cover:

1. idle;
2. microphone permission;
3. connecting;
4. listening;
5. user transcript;
6. assistant speaking;
7. entitlement denied;
8. quota unavailable;
9. snapshot stale or unavailable;
10. narrow laptop layout.

Store the generated originals and a manifest containing state, prompt, generation path, and file hash under `.empire/voice-visuals/`. `.empire/VOICE.md` embeds or links all ten so they materially document the UI states. The implemented page follows their shared palette, hierarchy, spacing, and control treatment.

## Testing

Rust tests begin red and cover JSON-RPC IDs, initialization, acknowledgement-versus-SDP behavior, error routing, process exit, timeout, idempotent stop, snapshot source gaps, UTF-8 truncation, and the no-tools/read-only thread instructions. Tauri command tests use a fake client boundary.

Frontend tests begin red and cover state transitions, transcript normalization, invocation payloads, partial-start cleanup, inactivity stop, error classification, sidebar routing, and snapshot-gap rendering. Production code is the minimum needed to satisfy each cycle.

The final Windows local-parity gate is the exact supported sequence from `.empire/BUILD.md`: workspace format and clippy, desktop Tauri format, desktop and web checks, and unit tests. Whole-repository Windows Tauri clippy findings documented there remain baseline exceptions; branch-caused warnings are not accepted.

## Live Proof and Delivery

Build and launch the local Tauri app without API credentials. Automated proof must show route rendering, microphone permission handling as far as the host permits, successful local SDP negotiation through the ChatGPT subscription, clean start/stop, and no mutating relay or filesystem action. If browser or desktop automation cannot grant a physical microphone, retain the successful app-server SDP proof plus deterministic WebRTC mocks and document that exact hardware boundary.

Review the complete diff for secret exposure, paid fallbacks, mutation paths, process leaks, SDP logging, unsafe snapshot expansion, unrelated files, and accessibility regressions. Push the feature branch, create a PR, wait for checks, fix branch-caused failures, squash-merge into `main`, verify the merge SHA, comment evidence on issue #13, close it, and update the Vault project note, repository note, and journal without manually pushing the Vault.
