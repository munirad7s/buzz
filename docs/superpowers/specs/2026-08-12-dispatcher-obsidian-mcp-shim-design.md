# Dispatcher Obsidian MCP Secret-Shim Design

## Goal

Restore the dispatcher’s agent-scoped Vault access without placing credentials in the public repository, Buzz messages, process arguments, global Claude configuration, or logs. Preserve the existing GitHub-via-`gh` and n8n-via-MCP paths, then prove all three through real read-only channel requests.

## Current Failure

The Nest configuration starts `obsidian-mcp-tools` directly. The installed binary now requires `OBSIDIAN_API_KEY`, so its stdio handshake exits before exposing tools. The existing key in `~/.secrets/master.env` matches the active Obsidian Local REST API credential; injecting that key for one process makes the unchanged binary expose 18 tools. n8n still exposes 24 tools through the existing secret shim.

Buzz Desktop, its ACP children, and Obsidian were not running during diagnosis. They must be started only after the corrected Nest configuration is installed so the dispatcher loads the new process environment at startup.

## Selected Design

Route `obsidian-mcp-tools` through the existing `.empire/tools/mcp-env-shim.js`, using an explicit one-key allowlist:

1. The public Nest config contains only the shim path, the environment-variable name, and the MCP binary path.
2. The shim reads `~/.secrets/master.env` at process start.
3. Only `OBSIDIAN_API_KEY` is added to the child environment.
4. The key value never appears in JSON, command arguments, repository files, Buzz messages, test output, or documentation.
5. The existing `permissions.deny` rules continue to block mutating Vault tools. The E2E uses only Vault reads.

This reuses the n8n pattern already deployed in the Nest. A wrapper that reads Obsidian’s private plugin data would create unnecessary coupling, while inline or global environment configuration would violate the isolation and secret-handling requirements.

## Repository Changes

- Update `.empire/tools/nest-mcp.json` so `obsidian-mcp-tools` starts through `mcp-env-shim.js` with only `OBSIDIAN_API_KEY` allowed.
- Add a focused regression test under `.empire/tools/test/` that proves:
  - the public Nest config contains no inline MCP environment values;
  - both secret-requiring MCP servers use the shim with exact allowlists;
  - the Obsidian server exposes tools when the existing credential is supplied through the shim;
  - removing the required variable produces the documented fail-closed exit.
- Correct `.empire/AGENTS.md`: Vault access now requires an injected credential, but the credential remains outside the Nest and public repository.
- Record the completed work in `.empire/PROGRESS.md` using the repository’s idempotent append tool.

No Buzz application source, global MCP registry, Park system, n8n workflow, server configuration, or production data is changed.

## Safe Live Rollout

1. Capture SHA-256 hashes for the global Claude settings, Park-related files, project-specific trust entry, current Nest files, and canonical repository files.
2. Verify the live credential exists and matches the active Obsidian Local REST API credential without printing either value.
3. Install only the reviewed canonical Nest MCP file and matching shim into `~/.buzz/`; keep the Nest settings file unchanged unless its canonical hash differs for an authorized reason.
4. Confirm global Claude MCP configuration and Park files retain their pre-rollout hashes. The only expected local changes are the Nest MCP file and, if stale, its copied shim.
5. Start Obsidian, wait for the authenticated Local REST endpoint, then start `%LOCALAPPDATA%\Buzz\buzz-desktop.exe`.
6. Restart the existing `claude` managed agent if needed so its ACP process starts after the Nest file’s modification time.
7. Run `nest-doctor.sh --format json`; require project trust, no process drift, and successful handshakes for all configured servers.

No app data is deleted or reset. Other managed agents and their records remain intact.

## Verification

### Automated

- Run the new focused regression test and all existing `.empire/tools/test/` tests relevant to the touched scripts/configuration.
- Run the Nest doctor before and after rollout. The pre-fix failure must identify the missing Obsidian credential; the post-fix run must report the Obsidian tool count and no process drift.
- Scan the branch diff and commit for common secret patterns and confirm no inline `env` object was added to the public MCP config.

### Independent Read-Only Expectations

Before channel E2E, obtain independent expected values:

- Vault: read the current `#1` heading from `99 System/Now.md` locally.
- GitHub: count open `ready` issues in `munirad7s/buzz` via `gh`.
- n8n: retrieve the last three execution IDs and statuses through the read-only API/MCP path.

### Real Channel E2E

In `#agent-lab`, mention the existing `@claude` dispatcher and require fresh answers for:

1. the current Vault focus;
2. the open `ready`-issue count;
3. the last three n8n execution IDs and statuses.

Compare every answer with the independently measured expectation. Capture message/event links or screenshots without exposing customer data, credentials, or private message bodies.

The inherited `Inbox-Triage` and `Lage?` checks may run only through their existing read-only or draft-only paths. They must not send mail, mutate n8n, deploy, post externally, or alter production data.

## Delivery and Completion

- Commit with DCO sign-off on `feat/3-obsidian-mcp-shim`.
- Push to `munirad7s/buzz`, open a PR against the fork’s `main`, wait for required CI, then squash-merge and delete the branch.
- Confirm the merged commit is on `origin/main` before treating the repository portion as complete.
- Post an evidence-focused issue comment, remove `in-progress`, close issue #3, and update the relevant epic checkbox if still open.
- Append 3–8 concise bullets to the 2026-08-12 Vault journal and refresh the canonical Buzz project/repository notes. Do not push the Vault manually.
- Do not access or deploy to `adas-hetzner`; `agency-infra#155` remains the sole server writer.
