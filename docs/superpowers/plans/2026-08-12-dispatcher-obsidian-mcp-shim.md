# Dispatcher Obsidian MCP Secret-Shim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the Buzz dispatcher’s Vault MCP by injecting the existing `OBSIDIAN_API_KEY` through the agent-scoped secret shim, then prove Vault, GitHub, and n8n through real read-only channel requests.

**Architecture:** The public Nest config names only environment-variable keys and executable paths. `mcp-env-shim.js` loads the allowlisted values from `~/.secrets/master.env` into each MCP child process; Claude’s Nest permissions remain the write guard. Repository tests prove the config contract with a fake stdio MCP, while the rollout uses the installed Vault MCP and existing credential for the real handshake and channel E2E.

**Tech Stack:** JSON MCP configuration, Node.js stdio MCP shim, Bash regression tests, PowerShell 5.1 rollout checks, Claude ACP in Buzz Desktop, GitHub CLI.

## Global Constraints

- No inline or global API key; no secret value in output, process arguments, repository files, commits, PRs, issues, or Buzz messages.
- Use only existing credentials from `~/.secrets/master.env`; no spend and no credential creation.
- Vault, GitHub, and n8n verification is read-only. Inbox triage and Lage are read-only/draft-only.
- No outbound mail, Telegram, payments, posts, deploys, production n8n mutations, or server access.
- Do not access or deploy to `adas-hetzner`; `agency-infra#155` remains the sole server writer.
- Preserve all foreign working-tree changes and all existing managed-agent records.
- Deliver through feature branch → fork PR → required CI → squash merge.

---

### Task 1: Lock the Nest secret contract with a failing regression test

**Files:**
- Create: `.empire/tools/test/nest-mcp-secrets-test.sh`
- Read: `.empire/tools/nest-mcp.json`
- Read: `.empire/tools/mcp-env-shim.js`
- Read: `.empire/tools/mcp-handshake.js`

**Interfaces:**
- Consumes: JSON fields `mcpServers["obsidian-mcp-tools"].command`, `.args[]`, and `.env` from `nest-mcp.json`.
- Produces: a standalone Bash test returning 0 only when the public config is secret-free and both secret-backed servers use exact allowlists.

- [ ] **Step 1: Create a fake stdio MCP used only by the test**

Inside the test’s `mktemp -d`, write `fake-obsidian-mcp.js`. It must exit 42 when `OBSIDIAN_API_KEY` is absent; otherwise it must answer MCP `initialize` and `tools/list` with one test tool. Never print the variable value.

- [ ] **Step 2: Add static config assertions**

Use `jq -e` to require:

```jq
.mcpServers["obsidian-mcp-tools"].command == "node" and
.mcpServers["obsidian-mcp-tools"].args[1:4] == ["--keys", "OBSIDIAN_API_KEY", "--"] and
.mcpServers["n8n-api"].args[1:4] == ["--keys", "N8N_API_URL,N8N_API_KEY", "--"] and
([.mcpServers[] | .env // {} | length] | add) == 0
```

Also fail if the tracked JSON contains a non-empty `env` object or a key-shaped literal.

- [ ] **Step 3: Add dynamic fail-closed and success assertions**

Create a temporary copy of the planned Obsidian entry whose child command is the fake server. Point `MCP_ENV_SHIM_FILE` at an empty env file and require handshake output beginning `FEHLER:exit-65-`. Then write only `OBSIDIAN_API_KEY=test-only-value` into the temporary env file and require handshake output `1`. Do not echo the file.

- [ ] **Step 4: Run the regression test and verify RED**

Run:

```bash
bash .empire/tools/test/nest-mcp-secrets-test.sh
```

Expected: FAIL because `obsidian-mcp-tools.command` still points directly to `mcp-server.exe` and its args do not contain the shim allowlist.

- [ ] **Step 5: Commit the RED test**

```bash
git add .empire/tools/test/nest-mcp-secrets-test.sh
git commit -s -m "Test agent-scoped MCP secret injection (#3)"
```

---

### Task 2: Route the Vault MCP through the existing shim and update canonical documentation

**Files:**
- Modify: `.empire/tools/nest-mcp.json`
- Modify: `.empire/AGENTS.md` section `MCP-Grundausstattung des Dispatchers`
- Test: `.empire/tools/test/nest-mcp-secrets-test.sh`

**Interfaces:**
- Consumes: `mcp-env-shim.js --keys OBSIDIAN_API_KEY -- C:/Users/rescue/Documents/Ai_Brain/.obsidian/plugins/mcp-tools/bin/mcp-server.exe`.
- Produces: the canonical `obsidian-mcp-tools` command that loads only `OBSIDIAN_API_KEY` before starting the installed binary.

- [ ] **Step 1: Make the minimal config change**

Set the Obsidian entry to:

```json
{
  "type": "stdio",
  "command": "node",
  "args": [
    "C:/Users/rescue/.buzz/mcp-env-shim.js",
    "--keys",
    "OBSIDIAN_API_KEY",
    "--",
    "C:/Users/rescue/Documents/Ai_Brain/.obsidian/plugins/mcp-tools/bin/mcp-server.exe"
  ],
  "env": {}
}
```

- [ ] **Step 2: Correct the operational documentation**

Change the Vault row from “no secrets” to “`OBSIDIAN_API_KEY` through shim”; describe that both n8n and Obsidian use exact allowlists, and add the Obsidian command example. Remove the obsolete claim that the Vault MCP needs no credential.

- [ ] **Step 3: Run the focused test and verify GREEN**

Run:

```bash
bash .empire/tools/test/nest-mcp-secrets-test.sh
```

Expected: all assertions PASS and exit 0.

- [ ] **Step 4: Verify the real installed binary through the canonical config**

Run the handshake with `MCP_ENV_SHIM_FILE` left at its default and capture only the tool count:

```bash
node .empire/tools/mcp-handshake.js .empire/tools/nest-mcp.json obsidian-mcp-tools 30
```

Expected: `18`. The key itself must not appear anywhere in output.

- [ ] **Step 5: Run static hygiene gates**

Run `git diff --check`, JSON parsing for both canonical Nest files, and a diff scan for key-like values. Expected: clean formatting, valid JSON, no secret literals.

- [ ] **Step 6: Commit the implementation and documentation**

```bash
git add .empire/tools/nest-mcp.json .empire/AGENTS.md
git commit -s -m "Restore dispatcher Vault MCP at process start (#3)"
```

---

### Task 3: Deliver the repository change through PR and CI

**Files:**
- Existing commits on `feat/3-obsidian-mcp-shim`
- GitHub PR in `munirad7s/buzz`

**Interfaces:**
- Consumes: clean branch based on `origin/main`, DCO-signed commits, focused test evidence.
- Produces: squash-merged PR whose merge commit is present on `origin/main`.

- [ ] **Step 1: Run the complete scoped verification**

Run the focused MCP test, `git diff --check origin/main...HEAD`, JSON parse checks, DCO trailer checks for every branch commit, and `git status --short`. Expected: all green and only intentional files committed.

- [ ] **Step 2: Push the branch and create the fork PR**

Use separate commands:

```bash
git push
gh pr create --repo munirad7s/buzz --base main --head feat/3-obsidian-mcp-shim --title "Restore dispatcher Vault MCP secret injection" --body-file .git/pr-3-body.md
```

The PR body lists RED/GREEN evidence and explicitly states no secret, spend, outbound, server, or n8n mutation.

- [ ] **Step 3: Wait for required CI and inspect failures at root cause**

Store the created PR number in `PR_NUMBER`, then run `gh pr checks $PR_NUMBER --repo munirad7s/buzz --watch`. Do not merge until every required check is green. Fix only failures caused by this branch.

- [ ] **Step 4: Squash-merge and verify remote main**

Run:

```bash
gh pr merge $PR_NUMBER --repo munirad7s/buzz --squash --delete-branch
git fetch origin
git merge-base --is-ancestor $MERGE_COMMIT origin/main
```

Expected: merge succeeds and ancestry check exits 0.

---

### Task 4: Roll the canonical Nest config into the live desktop safely

**Files:**
- Read/hash: `~/.claude.json`, `~/.claude/settings.json`, Park configuration files, `~/.buzz/.claude/settings.json`
- Copy: merged `.empire/tools/nest-mcp.json` → `~/.buzz/.mcp.json`
- Copy if stale: merged `.empire/tools/mcp-env-shim.js` → `~/.buzz/mcp-env-shim.js`

**Interfaces:**
- Consumes: merged canonical files and existing `OBSIDIAN_API_KEY` in `~/.secrets/master.env`.
- Produces: live Nest config with unchanged global/Park hashes and freshly started Obsidian/Buzz ACP processes.

- [ ] **Step 1: Capture a secret-free hash manifest**

Record path, existence, SHA-256, and modification time only. Include global Claude settings, Park-related config, live Nest config/settings/shim, and merged canonical files. Do not serialize file contents.

- [ ] **Step 2: Verify credential identity without disclosure**

Hash the parsed `OBSIDIAN_API_KEY` value from `master.env` and Obsidian Local REST `data.json` in memory. Require equal hashes and print only `match=true` plus lengths.

- [ ] **Step 3: Install only authorized Nest files**

Copy the merged canonical `nest-mcp.json` to `~/.buzz/.mcp.json`; copy the shim only if its hash differs. Do not change global Claude files, Park files, managed-agent JSON, or Nest permission settings.

- [ ] **Step 4: Prove hash protection**

Recompute hashes. Require every protected global/Park/settings file to equal its baseline. Require live Nest MCP and shim hashes to equal their merged canonical files.

- [ ] **Step 5: Start Obsidian and Buzz Desktop safely**

Start Obsidian if absent and poll the authenticated Local REST root until it reports the expected service. Start `%LOCALAPPDATA%\Buzz\buzz-desktop.exe` if absent with a hidden helper window. Wait for `buzz-desktop`, `buzz-acp`, and `buzz-dev-mcp` processes. Do not start the legacy Whisper `Buzz.exe`.

- [ ] **Step 6: Verify loaded process state**

Run `nest-doctor.sh --format json` through Git Bash. Require `trust_accepted=true`, all server statuses `ok`, Obsidian handshake `18`, n8n handshake `24`, and `process_drift=nein` (or the doctor’s current equivalent for no drift).

---

### Task 5: Prove real read-only channel access and close the issue

**Files:**
- Update: `.empire/PROGRESS.md` via `.empire/tools/progress-append.sh` after merge and issue closure
- Append: `C:/Users/rescue/Documents/Ai_Brain/01 Journal/2026-08/2026-08-12.md`
- Update: `C:/Users/rescue/Documents/Ai_Brain/03 Projects/buzz-command-center.md`
- Update: `C:/Users/rescue/Documents/Ai_Brain/07 Repositories/munirad7s-buzz.md`

**Interfaces:**
- Consumes: running dispatcher, independent Vault/GitHub/n8n expectations, merged PR evidence.
- Produces: channel event links/screenshots, closed issue #3, clean labels, updated canonical status and journal.

- [ ] **Step 1: Measure independent expectations read-only**

Read the current `## #1` heading from `99 System/Now.md`; count open `ready` issues using `gh`; retrieve the last three n8n execution IDs/statuses with the existing read-only API/MCP path. Store only non-secret expected values.

- [ ] **Step 2: Send three fresh `@claude` questions in `#agent-lab`**

Ask separately for the Vault focus, Buzz ready-issue count, and last three n8n executions/statuses. These Buzz messages are the issue-authorized E2E fixture. Poll the corresponding threads until the dispatcher answers or produces a concrete runtime error.

- [ ] **Step 3: Compare answers and capture evidence**

Require exact semantic agreement with all three independent expectations. Capture event/deep links and, if needed, screenshots through the repository’s approved screenshot path. Do not include secrets, customer data, or private message bodies.

- [ ] **Step 4: Run inherited checks within guardrails**

Run `Inbox-Triage` only through its existing read-only categorization and draft-only path; run `Lage?` only through the existing read-only `lagebild.sh` path. Confirm no message send, n8n mutation, deploy, payment, or external post occurred.

- [ ] **Step 5: Close GitHub state cleanly**

Post an evidence-focused issue comment linking the PR/merge and three E2E proofs. Remove `in-progress`, close issue #3, and update epic #19 only if its #3 checkbox is still open. Verify the final issue is closed with no `ready`, `in-progress`, or `blocked-munir` label.

- [ ] **Step 6: Record progress and Vault state**

Use `progress-append.sh` with the actual PR, merge SHA, issue, and channel root. Append 3–8 journal bullets, update the Buzz project/repository notes’ verification timestamps and next action, and read all changes back. Never push the Vault manually.

- [ ] **Step 7: Final verification and worktree cleanup**

Re-run the focused test, live Nest doctor, final issue query, PR query, protected hash comparison, and Vault read-back. Remove only `C:/Users/rescue/projects/buzz-agent-3` after confirming no uncommitted files; prune worktrees without touching foreign entries.
