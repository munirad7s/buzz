#!/usr/bin/env bash
# progress-append.sh — idempotent PROGRESS.md-Zeile nach verifiziertem Merge + geschlossenem Issue
#
# Usage:
#   bash .empire/tools/progress-append.sh \
#     --repo <owner/repo> \
#     --issue <number> \
#     --worker <agent-name> \
#     --pr <number> \
#     --channel-root <hex-event-id> \
#     [--result "<summary>"] \
#     [--progress-file <path>]
#
# Verification (fail-closed, nie Erfolg schätzen):
#   1. PR ist gemerged (gh pr view --json mergedAt)
#   2. Issue ist geschlossen (gh issue view --json state)
#   3. Kein Duplikat (Issue+PR bereits in PROGRESS.md)
#
# Exit codes:
#   0 — Zeile angehängt (oder bereits vorhanden, idempotent)
#   1 — Parameterfehler
#   2 — PR nicht gemerged
#   3 — Issue nicht geschlossen
#   4 — gh nicht verfügbar oder API-Fehler
#   5 — PROGRESS.md nicht schreibbar
#
# Folge aus buzz#134.

set -euo pipefail

REPO=""
ISSUE=""
WORKER=""
PR=""
CHANNEL_ROOT=""
RESULT=""
PROGRESS_FILE=".empire/PROGRESS.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --worker) WORKER="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --channel-root) CHANNEL_ROOT="$2"; shift 2 ;;
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
if [[ -n "$_missing" ]]; then
  echo "ERROR: missing required arguments:${_missing}" >&2
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

# --- 3. Idempotenz: Issue+PR bereits in PROGRESS.md? ---
if [[ ! -f "$PROGRESS_FILE" ]]; then
  echo "ERROR: PROGRESS file not found: $PROGRESS_FILE" >&2
  exit 5
fi

# Suchpattern: sowohl "#<ISSUE>" als auch "PR #<PR>" in derselben Zeile
_dup_check=$(grep -c "#${ISSUE}.*PR #${PR}\|PR #${PR}.*#${ISSUE}" "$PROGRESS_FILE" 2>/dev/null || true)
if [[ "$_dup_check" -gt 0 ]]; then
  echo "OK (idempotent): line for #$ISSUE / PR #$PR already in $PROGRESS_FILE ($_dup_check match(es))"
  exit 0
fi

# --- 4. Zeile zusammenbauen und anhängen ---
_timestamp=$(date '+%Y-%m-%d %H:%M')
_short_sha="${_merge_sha:0:12}"

# Result-Text: Default wenn leer
if [[ -z "$RESULT" ]]; then
  RESULT="merged + issue closed"
fi

# Kanonisches Format:
# YYYY-MM-DD HH:MM | #<issue> | <worker> | PR #<pr> | merge <short-sha> | ch.<root-prefix> | <result>
_line="${_timestamp} | #${ISSUE} | ${WORKER} | PR #${PR} | merge ${_short_sha} | ch.${CHANNEL_ROOT:0:12} | ${RESULT}"

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
