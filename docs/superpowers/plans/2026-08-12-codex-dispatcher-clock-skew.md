# Codex Dispatcher and Relay Clock-Skew Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the existing ChatGPT-subscription Codex managed agent the no-cost buzz#3 dispatcher, safely authenticate despite a skewed Windows clock, preserve hard MCP write denies, and prove the three read-only channel answers.

**Architecture:** `buzz-acp` samples authenticated WSS response time into a bounded shared auth-only clock used by NIP-42/NIP-98. The existing agent-scoped `~/.codex-buzz` starts Vault and n8n through the Nest secret shim and applies Codex-native tool deny lists. GitHub remains `gh`; the Nest cwd and `AGENTS.md` persona remain unchanged.

---

### Task 1: Lock clock behavior with failing tests

**Files:** `crates/buzz-acp/src/relay.rs`

- [x] Add tests for standard `Date`, production `cDate`, malformed/missing headers, non-WSS rejection, >24-hour rejection, >30-second RTT rejection, midpoint compensation, and saturating adjusted timestamps.
- [x] Add auth-event tests proving only NIP-42 and NIP-98 `created_at` use the offset while their required tags/signatures remain valid.
- [x] Run the focused tests and capture the expected RED result before production code.

### Task 2: Implement the bounded shared auth clock

**Files:** `crates/buzz-acp/src/relay.rs`

- [x] Add the private atomic clock and pure sample-validation helpers.
- [x] Measure the WSS handshake interval, parse `Date`/`cDate`, and refresh the clock on initial connect and reconnect.
- [x] Use `custom_created_at` only in the NIP-42 and NIP-98 event builders.
- [x] Keep relay verifier constants and ordinary event builders unchanged.
- [x] Run focused tests, `cargo fmt`, and the full `buzz-acp` test suite; commit GREEN with DCO.

### Task 3: Canonicalize the Codex dispatcher MCP and deny policy

**Files:** `.empire/tools/codex-agent-home.sh`, `.empire/tools/test/codex-dispatcher-mcp-test.sh`, `.empire/AGENTS.md`

- [x] Add a focused regression that runs `codex-agent-home.sh setup` against temporary homes and expects exactly the two shim-backed servers, no inline secret values, and the same 17 denied tools as the Claude Nest.
- [x] Capture RED before changing the setup script.
- [x] Make `setup` install/update a marked dispatcher MCP block idempotently without replacing unrelated agent-scoped settings; make `verify` check semantics without printing values.
- [x] Update the Empire runbook and stale Claude-only blocker language.
- [x] Run the focused test, existing secret-shim tests, shell syntax checks, and live-config dry runs; commit with DCO.

### Task 4: Review and deliver the branch

- [ ] Run `git diff --check`, focused tests, `cargo test -p buzz-acp`, clippy/check gates, relevant Empire tests, `just ci`, DCO checks, and secret scans.
- [ ] Review the diff specifically for timestamp trust expansion, unbounded offsets, secret/log leaks, MCP deny drift, and unrelated changes.
- [ ] Push `fix/3-agent-clock-skew`, create the PR, wait for every required check, fix only branch-caused failures, squash-merge, and verify the merge is on `origin/main`.

### Task 5: Roll out locally with hash protection

- [ ] Capture hashes/semantics for the installed Buzz binaries, managed-agent store, `~/.codex`, `~/.codex-buzz`, Claude/Park files, and Nest files without printing secret-bearing content.
- [ ] Build the merged `buzz-acp.exe`; stop only local affected Buzz processes; create rollback copies; replace the binary only when the baseline hash still matches.
- [ ] Run `codex-agent-home.sh setup` with the existing hardlinked auth, verify the link count, MCP entries, deny lists, and unchanged interactive config.
- [ ] Ensure the existing `codex` managed agent still uses `C:/Users/rescue/.buzz`, its existing identity, and `CODEX_HOME=~/.codex-buzz`; restart Desktop/agent locally. Do not deploy a server.

### Task 6: Prove the live channels and close only on evidence

- [ ] Run Codex login/readiness checks, `nest-doctor`, live Vault/n8n handshakes, and independent read-only Vault/GitHub/n8n expectations.
- [ ] Send exactly the three issue questions as separate `#agent-lab` roots to the Codex dispatcher and wait for its replies.
- [ ] Compare all answers exactly; capture event IDs/links without customer data or credentials.
- [ ] If ordinary event freshness rejects replies, document that separate technical gate and leave #3 open without `blocked-munir`; do not broaden the auth-only offset.
- [ ] If all three replies pass, comment evidence, remove `in-progress`/`blocked-munir`, close #3, and update the epic/progress record as applicable.
- [ ] Update the Vault project/repository notes and append 3–8 journal bullets, then read back the changes. Never push the Vault manually.
