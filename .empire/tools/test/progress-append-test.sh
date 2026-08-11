#!/usr/bin/env bash
# test/progress-append-test.sh — Tests für progress-append.sh (buzz#134)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$SCRIPT_DIR/../progress-append.sh"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- Mock-Helper: gh durch einen Stub ersetzen ---
setup_mock_gh() {
  local mock_dir="$TMPDIR_TEST/bin"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
_ARGS=("$@")

if [[ "${_ARGS[0]}" == "pr" && "${_ARGS[1]}" == "view" ]]; then
  if [[ "${MOCK_PR_EXISTS:-yes}" == "no" ]]; then
    echo "could not find pull request" >&2
    exit 1
  fi
  _field="" _jq="" _in_json=false _in_jq=false
  for a in "${_ARGS[@]:2}"; do
    if $_in_json; then _field="$a"; _in_json=false; continue; fi
    if $_in_jq; then _jq="$a"; _in_jq=false; continue; fi
    [[ "$a" == "--json" ]] && _in_json=true
    [[ "$a" == "--jq" ]] && _in_jq=true
  done
  if [[ "$_field" == "mergedAt" ]]; then
    [[ "${MOCK_PR_MERGED:-yes}" == "yes" ]] && echo "2026-08-11T18:00:00Z" || echo "null"
  elif [[ "$_field" == "mergeCommit" ]]; then
    if [[ "${MOCK_PR_MERGED:-yes}" == "yes" ]]; then
      [[ "$_jq" == *".oid"* ]] && echo "${MOCK_MERGE_SHA:-abcdef1234567890}" || echo "{\"oid\":\"${MOCK_MERGE_SHA:-abcdef1234567890}\"}"
    else echo "null"; fi
  fi
  exit 0
fi

if [[ "${_ARGS[0]}" == "issue" && "${_ARGS[1]}" == "view" ]]; then
  if [[ "${MOCK_ISSUE_EXISTS:-yes}" == "no" ]]; then echo "could not find issue" >&2; exit 1; fi
  _field="" _in_json=false
  for a in "${_ARGS[@]:2}"; do
    if $_in_json; then _field="$a"; _in_json=false; continue; fi
    [[ "$a" == "--json" ]] && _in_json=true
  done
  [[ "$_field" == "state" ]] && echo "${MOCK_ISSUE_STATE:-CLOSED}"
  exit 0
fi
echo "MOCK GH: unknown: ${_ARGS[*]}" >&2; exit 1
MOCK_EOF
  chmod +x "$mock_dir/gh"
  export PATH="$mock_dir:$PATH"
}

setup_progress_file() {
  local prog="$TMPDIR_TEST/PROGRESS_$1.md"
  printf '# buzz_empire — PROGRESS\n\n2026-08-01 11:30 | Setup | Backlog angelegt\n' > "$prog"
  echo "$prog"
}

count_matches() { local n; n=$(grep -c "$2" "$1" 2>/dev/null) || n=0; echo "$n"; }

# ============================================================
echo "Test 1: green run (merged PR + closed issue)"
PROG=$(setup_progress_file 1)
setup_mock_gh
export MOCK_PR_MERGED=yes MOCK_ISSUE_STATE=CLOSED MOCK_MERGE_SHA=e2948b8a1b2c3d4e5f6g7h8
OUT=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root b6037610a3e8ea56b51838364b2a7125cb77609e842721542943b6585dba8d3c \
  --result "test green" --progress-file "$PROG" 2>&1)
RC=$?
[ $RC -eq 0 ] && ok "exit 0" || ko "exit $RC: $OUT"
N=$(count_matches "$PROG" '#42.*PR #99')
[ "$N" -eq 1 ] && ok "one line added" || ko "expected 1, got $N"
LINE=$(grep '#42.*PR #99' "$PROG" 2>/dev/null || true)
echo "$LINE" | grep -q '| merge e2948b8a1b2c |' && ok "merge SHA correct" || ko "merge SHA wrong: [$LINE]"
echo "$LINE" | grep -q 'ch.b6037610a3e8' && ok "channel-root prefix" || ko "channel-root missing: [$LINE]"

# ============================================================
echo "Test 2: idempotency (repeat call)"
PROG=$(setup_progress_file 2)
setup_mock_gh
export MOCK_PR_MERGED=yes MOCK_ISSUE_STATE=CLOSED MOCK_MERGE_SHA=e2948b8a1b2c3d4e5f6g7h8
bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root b6037610a3e8ea56 --result "test" --progress-file "$PROG" >/dev/null 2>&1
N1=$(count_matches "$PROG" '#42.*PR #99')
OUT2=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root b6037610a3e8ea56 --result "test" --progress-file "$PROG" 2>&1)
RC2=$?
N2=$(count_matches "$PROG" '#42.*PR #99')
[ "$N1" -eq 1 ] && [ "$N2" -eq 1 ] && ok "no duplicate" || ko "got N1=$N1 N2=$N2"
[ $RC2 -eq 0 ] && ok "repeat exits 0" || ko "repeat exit $RC2"
echo "$OUT2" | grep -qi 'already' && ok "idempotent message" || ko "no idempotent msg: $OUT2"

# ============================================================
echo "Test 3: open PR -> exit 2"
PROG=$(setup_progress_file 3)
setup_mock_gh
export MOCK_PR_MERGED=no MOCK_ISSUE_STATE=CLOSED
OUT3=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root b6037610a3e8ea56 --progress-file "$PROG" 2>&1)
RC3=$?
[ $RC3 -eq 2 ] && ok "exit 2" || ko "expected 2, got $RC3: $OUT3"
N=$(count_matches "$PROG" '#42.*PR #99')
[ "$N" -eq 0 ] && ok "no line added" || ko "line added despite open PR"

# ============================================================
echo "Test 4: open issue -> exit 3"
PROG=$(setup_progress_file 4)
setup_mock_gh
export MOCK_PR_MERGED=yes MOCK_ISSUE_STATE=OPEN MOCK_MERGE_SHA=abcdef1234567890
OUT4=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root b6037610a3e8ea56 --progress-file "$PROG" 2>&1)
RC4=$?
[ $RC4 -eq 3 ] && ok "exit 3" || ko "expected 3, got $RC4: $OUT4"
N=$(count_matches "$PROG" '#42.*PR #99')
[ "$N" -eq 0 ] && ok "no line added" || ko "line added despite open issue"

# ============================================================
echo "Test 5: nonexistent PR -> exit 4"
PROG=$(setup_progress_file 5)
setup_mock_gh
export MOCK_PR_EXISTS=no MOCK_ISSUE_STATE=CLOSED
OUT5=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 999 \
  --channel-root b6037610a3e8ea56 --progress-file "$PROG" 2>&1)
RC5=$?
[ $RC5 -eq 4 ] && ok "exit 4" || ko "expected 4, got $RC5: $OUT5"
N=$(count_matches "$PROG" '#42.*PR #999')
[ "$N" -eq 0 ] && ok "no line added" || ko "line added despite nonexistent PR"

# ============================================================
echo "Test 6: missing params -> exit 1"
PROG=$(setup_progress_file 6)
setup_mock_gh
OUT6=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm \
  --channel-root b6037610a3e8ea56 --progress-file "$PROG" 2>&1)
RC6=$?
[ $RC6 -eq 1 ] && ok "exit 1" || ko "expected 1, got $RC6: $OUT6"

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
