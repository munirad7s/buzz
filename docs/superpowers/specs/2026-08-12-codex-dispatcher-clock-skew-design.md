# Codex Dispatcher and Relay Clock-Skew Design

## Goal

Finish buzz#3 without Claude, paid upgrades, API keys, Windows clock changes, server changes, or weaker relay replay checks. The existing Buzz-managed Codex ACP agent becomes the dispatcher, retains the Nest working directory and `AGENTS.md` persona, receives the Vault and n8n MCP servers through the existing secret shim, uses `gh` for GitHub, and answers the three issue-authorized read-only questions in `#agent-lab`.

## Constraints

- Use the existing ChatGPT-subscription login shared through the agent-scoped `~/.codex-buzz` home. Never use an API key or paid fallback.
- Keep Munir's interactive `~/.codex`, global Claude configuration, Park system, and unrelated managed agents unchanged.
- Read-only access for Vault, GitHub, and n8n. Inbox triage and Lage remain read-only/draft-only.
- Never print, persist, or commit credential values. The public configuration names variables only.
- Do not change the Windows clock, relay freshness windows, server deployment, or `agency-infra#155` ownership.
- Apply the derived relay offset only when signing NIP-42 and NIP-98 authentication events in `buzz-acp`.

## Dispatcher Selection

The existing `codex` managed agent is promoted to the dispatcher role. This is a role/configuration change, not a second agent identity or another login. Its existing `CODEX_HOME=~/.codex-buzz` keeps the ChatGPT subscription token shared by hardlink with Munir's Codex login while isolating MCP and skill configuration from interactive sessions.

The agent continues to start in `C:/Users/rescue/.buzz`, where root `AGENTS.md` supplies the dispatcher persona and Buzz channel protocol. GitHub stays on the authenticated `gh` CLI. Vault and n8n are added only to `~/.codex-buzz/config.toml` by the canonical `codex-agent-home.sh` recovery script.

Both MCP entries launch through `C:/Users/rescue/.buzz/mcp-env-shim.js`:

- `obsidian-mcp-tools` receives only `OBSIDIAN_API_KEY`.
- `n8n-api` receives only `N8N_API_URL,N8N_API_KEY`.

The values remain in `~/.secrets/master.env`. The Codex config contains no inline environment map or credential value.

Codex's native `disabled_tools` lists reproduce the existing Nest deny policy exactly: ten mutating n8n tools and seven mutating Vault tools are hidden after MCP discovery. `append_to_vault_file` remains available for the separately documented journal fallback, but the buzz#3 E2E does not call it.

## Relay Clock Source

`buzz-acp` derives a bounded offset from the HTTP `Date` header on the authenticated WSS upgrade response. The production edge currently emits the equivalent custom `cDate` header, so the parser accepts `Date` first and `cDate` second. A sample is trusted only when all conditions hold:

1. the configured relay scheme is `wss`;
2. TLS hostname/certificate verification has completed successfully in `connect_async`;
3. the header parses as an RFC 2822/HTTP date;
4. the measured handshake round trip is at most the existing 30-second connect timeout;
5. the resulting absolute offset is at most 24 hours.

The offset is calculated against the midpoint of the local request interval to reduce network-latency error. Missing, malformed, insecure, slow, or out-of-bound samples fail closed to the previous bounded value (zero on first connection). The accepted value may be logged only as a signed number of seconds; no headers, tokens, challenges, keys, or events are logged.

One shared atomic clock lives with `HarnessRelay`. Initial authentication samples it before responding to the NIP-42 challenge, reconnects refresh it, and cloned REST clients read the current value for every newly signed NIP-98 request. Timestamp arithmetic is saturating and never produces a negative Unix timestamp.

## Security Boundary

The relay's existing ±60-second NIP-42 and NIP-98 verifiers remain byte-for-byte unchanged. The offset does not alter event filtering, subscriptions, prompt timing, ordinary Nostr event timestamps, process time, Windows time, filesystem mtimes, logs, or any other client. This limits a compromised or erroneous edge timestamp to authentication-event creation, and the 24-hour cap prevents arbitrary time injection.

An authenticated TLS edge can still supply a wrong date. That risk already lies inside the relay trust boundary; the explicit scheme, certificate, RTT, and magnitude gates prevent an unauthenticated network peer or pathological response from silently becoming a general system clock.

Ordinary Buzz messages retain their existing local `created_at`. The live rollout must therefore test the full channel path after auth. If the relay rejects the dispatcher's reply at the independent ±15-minute ingest freshness gate, that is a separate, concrete technical dependency and buzz#3 remains open; this change will not broaden the offset contrary to the authorized scope.

## Repository Changes

- Add a private bounded authentication clock in `crates/buzz-acp/src/relay.rs` and apply it only to NIP-42/NIP-98 builders.
- Add regression tests for `Date`/`cDate`, WSS-only trust, midpoint calculation, bounds, saturating timestamps, and both auth event kinds.
- Extend `.empire/tools/codex-agent-home.sh` so `setup` idempotently installs the two dispatcher MCP definitions and `verify` proves their commands, allowlisted secret names, and exact deny lists without reading secret values.
- Add focused shell regression coverage for the generated agent-scoped Codex config.
- Update `.empire/AGENTS.md` with the Codex dispatcher fallback, MCP/deny wiring, clock security reasoning, rollout, and measured evidence.

## Verification and Delivery

Use a clean feature worktree and DCO-signed commits. Run focused RED/GREEN tests, `cargo fmt`, `cargo test -p buzz-acp`, relevant Empire shell tests, secret scans, `cargo clippy`/`just ci` as required, and an independent security review. Push a feature branch, open a PR, wait for green CI, squash-merge, and verify the merge on `origin/main`.

After merge, build and hash the local `buzz-acp.exe`, stop only the affected managed agent/Desktop process, replace only the reviewed binary and agent-scoped Codex config with rollback copies, verify protected configuration hashes, and restart locally. No server is contacted for deployment.

Run `codex login status`, `codex-agent-home.sh verify`, `nest-doctor.sh --format json`, and actual read-only MCP probes. Then send exactly these separate roots in `#agent-lab` to the Codex dispatcher and compare answers with independent expectations:

1. `@dispatcher Was ist Fokus #1 in Now.md?`
2. `@dispatcher Wie viele offene ready-Issues hat munirad7s/buzz?`
3. `@dispatcher Letzte 3 n8n-Executions mit Status?`

Close #3 and remove work labels only when all three channel answers are present and correct. Otherwise leave it open and document the precise transport/runtime failure. Finish with the issue evidence, Vault project/repository notes, and the session journal; never push the Vault manually.
