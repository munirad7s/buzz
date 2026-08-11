#!/usr/bin/env bash
# progress-append.sh — idempotent PROGRESS.md-Zeile nach verifiziertem Merge + geschlossenem Issue
#
# Usage:
#   bash .empire/tools/progress-append.sh \
#     --repo <owner/repo> \
#     --issue <number> \
#     --worker <agent-name> \
#     --pr <number> \
#     --channel-root <64-hex-event-id> \
#     --expected-head <40-hex-sha> \
#     [--result "<summary>"] \
#     [--progress-file <path>]
#
# Verification (fail-closed, nie Erfolg schätzen):
#   1. PR ist gemerged (gh pr view --json mergedAt)
#   2. PR head stimmt mit --expected-head überein (headRefOid)
#   3. Issue ist geschlossen (gh issue view --json state)
#   4. Issue steht in PR closingIssuesReferences (gleicher owner/repo)
#   5. Kein Duplikat (repo+issue+PR bereits in PROGRESS.md)
#
# Exit codes:
#   0 — Zeile angehängt (oder bereits vorhanden, idempotent)
#   1 — Parameterfehler / Validierung
#   2 — PR nicht gemerged
#   3 — Issue nicht geschlossen
#   4 — gh nicht verfügbar oder API-Fehler
#   5 — PROGRESS.md nicht schreibbar
#   6 — Head mismatch (PR head != expected-head)
#   7 — Issue nicht in PR closingIssuesReferences
#
# Folge aus buzz#134.

set -euo pipefail

REPO=""
ISSUE=""
WORKER=""
PR=""
CHANNEL_ROOT=""
EXPECTED_HEAD=""
RESULT=""
PROGRESS_FILE=".empire/PROGRESS.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --worker) WORKER="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --channel-root) CHANNEL_ROOT="$2"; shift 2 ;;
    --expected-head) EXPECTED_HEAD="$2"; shift 2 ;;
    --result) RESULT="$2"; shift 2 ;;
    --progress-file) PROGRESS_FILE="$2"; shift 2 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# --- Parameter-Validierung ---
_missing=""
[[ -z "$REPO" ]] && _missing+=" --repo"
[[ -z "$ISSUE" ]] && _missing+=" --issue"
[[ -z "$WORKER" ]] && _missing+=" --worker"
[[ -z "$PR" ]] && _missing+=" --pr"
[[ -z "$CHANNEL_ROOT" ]] && _missing+=" --channel-root"
[[ -z "$EXPECTED_HEAD" ]] && _missing+=" --expected-head"
if [[ -n "$_missing" ]]; then
  echo "ERROR: missing required arguments:${_missing}" >&2
  exit 1
fi

# --- Gap 4: Input-Validierung ---

# Issue und PR müssen numerisch sein
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --issue must be a positive integer, got '$ISSUE'" >&2
  exit 1
fi
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --pr must be a positive integer, got '$PR'" >&2
  exit 1
fi

# Channel-Root muss 64 Hex-Zeichen sein
if ! [[ "$CHANNEL_ROOT" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: --channel-root must be 64 hex characters, got '${CHANNEL_ROOT:0:20}...' ($(echo -n "$CHANNEL_ROOT" | wc -c) chars)" >&2
  exit 1
fi

# Expected-Head muss 40 Hex-Zeichen sein
if ! [[ "$EXPECTED_HEAD" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "ERROR: --expected-head must be 40 hex characters, got '${EXPECTED_HEAD:0:20}...' ($(echo -n "$EXPECTED_HEAD" | wc -c) chars)" >&2
  exit 1
fi

# Worker darf kein Newline oder Pipe enthalten
if [[ "$WORKER" == *$'\n'* || "$WORKER" == *"|"* ]]; then
  echo "ERROR: --worker must not contain newline or pipe ('|')" >&2
  exit 1
fi

# Result darf kein Newline oder Pipe enthalten
if [[ -n "$RESULT" ]]; then
  if [[ "$RESULT" == *$'\n'* || "$RESULT" == *"|"* ]]; then
    echo "ERROR: --result must not contain newline or pipe ('|')" >&2
    exit 1
  fi
fi

# Repo muss owner/name Format haben
if ! [[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: --repo must be owner/repo format, got '$REPO'" >&2
  exit 1
fi

# --- gh verfügbar? ---
if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI not found in PATH" >&2
  exit 4
fi

# --- 1. PR gemerged? ---
_pr_merged=$(gh pr view "$PR" -R "$REPO" --json mergedAt --jq '.mergedAt' 2>&1) || {
  echo "ERROR: cannot query PR #$PR on $REPO: $_pr_merged" >&2
  exit 4
}
if [[ "$_pr_merged" == "null" || -z "$_pr_merged" ]]; then
  echo "ERROR: PR #$PR on $REPO is NOT merged (mergedAt=null)" >&2
  exit 2
fi

# --- Gap 1: Head-Verifikation ---
_pr_head=$(gh pr view "$PR" -R "$REPO" --json headRefOid --jq '.headRefOid' 2>&1) || {
  echo "ERROR: cannot query headRefOid for PR #$PR: $_pr_head" >&2
  exit 4
}
if [[ "$_pr_head" != "$EXPECTED_HEAD" ]]; then
  echo "ERROR: PR #$PR head mismatch — expected $EXPECTED_HEAD, got $_pr_head" >&2
  exit 6
fi

# --- Merge-Commit SHA holen ---
_merge_sha=$(gh pr view "$PR" -R "$REPO" --json mergeCommit --jq '.mergeCommit.oid' 2>&1) || {
  echo "ERROR: cannot extract merge commit SHA for PR #$PR: $_merge_sha" >&2
  exit 4
}
if [[ "$_merge_sha" == "null" || -z "$_merge_sha" ]]; then
  echo "ERROR: PR #$PR merged but mergeCommit.oid is null" >&2
  exit 2
fi

# --- 2. Issue geschlossen? ---
_issue_state=$(gh issue view "$ISSUE" -R "$REPO" --json state --jq '.state' 2>&1) || {
  echo "ERROR: cannot query issue #$ISSUE on $REPO: $_issue_state" >&2
  exit 4
}
if [[ "$_issue_state" != "CLOSED" ]]; then
  echo "ERROR: issue #$ISSUE on $REPO is $_issue_state, not CLOSED" >&2
  exit 3
fi

# --- Gap 2: Issue in PR closingIssuesReferences? ---
_closing_issues=$(gh pr view "$PR" -R "$REPO" --json closingIssuesReferences --jq '.closingIssuesReferences[].number' 2>&1) || {
  echo "ERROR: cannot query closingIssuesReferences for PR #$PR: $_closing_issues" >&2
  exit 4
}
if ! echo "$_closing_issues" | grep -qx "$ISSUE"; then
  echo "ERROR: issue #$ISSUE is not in PR #$PR closingIssuesReferences on $REPO" >&2
  exit 7
fi

# --- 3. Idempotenz: repo+issue+PR bereits in PROGRESS.md? ---
if [[ ! -f "$PROGRESS_FILE" ]]; then
  echo "ERROR: PROGRESS file not found: $PROGRESS_FILE" >&2
  exit 5
fi

# Gap 3: Idempotenz-Key mit repo, um Cross-Repo-Kollisionen zu vermeiden
# Sucht nach repo+issue UND pr in derselben Zeile (fixed-string, keine Regex)
_dup_check=$(grep -F "${REPO} | #${ISSUE}" "$PROGRESS_FILE" 2>/dev/null | grep -Fc "PR #${PR}" || true)
if [[ "$_dup_check" -gt 0 ]]; then
  echo "OK (idempotent): line for ${REPO}|#${ISSUE}|PR #${PR} already in $PROGRESS_FILE ($_dup_check match(es))"
  exit 0
fi

# --- 4. Zeile zusammenbauen und anhängen ---
_timestamp=$(date '+%Y-%m-%d %H:%M')
_short_sha="${_merge_sha:0:12}"

# Result-Text: Default wenn leer
if [[ -z "$RESULT" ]]; then
  RESULT="merged + issue closed"
fi

# Gap 3: Kanonisches Format mit owner/repo:
# YYYY-MM-DD HH:MM | <owner/repo> | #<issue> | <worker> | PR #<pr> | merge <short-sha> | ch.<root-prefix> | <result>
_line="${_timestamp} | ${REPO} | #${ISSUE} | ${WORKER} | PR #${PR} | merge ${_short_sha} | ch.${CHANNEL_ROOT:0:12} | ${RESULT}"

# Sicherstellen, dass Datei mit newline endet
_last_byte=$(tail -c 1 "$PROGRESS_FILE" 2>/dev/null | od -An -tx1 | tr -d ' ')
if [[ "$_last_byte" != "0a" && -s "$PROGRESS_FILE" ]]; then
  echo "" >> "$PROGRESS_FILE"
fi

# Atomarer Append (Append ist die einzige kollisionsfreie Operation bei parallelen Sessions)
echo "$_line" >> "$PROGRESS_FILE" || {
  echo "ERROR: cannot write to $PROGRESS_FILE" >&2
  exit 5
}

echo "OK: appended to $PROGRESS_FILE:"
echo "  $_line"
exit 0
