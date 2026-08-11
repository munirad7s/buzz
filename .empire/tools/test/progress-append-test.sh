#!/usr/bin/env bash
# test/progress-append-test.sh — Tests für progress-append.sh (buzz#134)
# Covers: original tests + 4 codex gaps (expected-head, closing-issues,
#         cross-repo idempotency, input validation)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$SCRIPT_DIR/../progress-append.sh"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

GOOD_CH="b6037610a3e8ea56b51838364b2a7125cb77609e842721542943b6585dba8d3c"
GOOD_HEAD="abcdef1234567890abcdef1234567890abcdef12"
WRONG_HEAD="9999999999999999999999999999999999999999"

setup_mock_gh() {
  local mock_dir="$TMPDIR_TEST/bin"
  mkdir -p "$mock_dir"
  cat > "$mock_dir/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
_ARGS=("$@")
if [[ "${_ARGS[0]}" == "pr" && "${_ARGS[1]}" == "view" ]]; then
  if [[ "${MOCK_PR_EXISTS:-yes}" == "no" ]]; then echo "could not find pull request" >&2; exit 1; fi
  _field="" _jq="" _in_json=false _in_jq=false
  for a in "${_ARGS[@]:2}"; do
    if $_in_json; then _field="$a"; _in_json=false; continue; fi
    if $_in_jq; then _jq="$a"; _in_jq=false; continue; fi
    [[ "$a" == "--json" ]] && _in_json=true
    [[ "$a" == "--jq" ]] && _in_jq=true
  done
  case "$_field" in
    mergedAt) [[ "${MOCK_PR_MERGED:-yes}" == "yes" ]] && echo "2026-08-11T18:00:00Z" || echo "null" ;;
    mergeCommit)
      if [[ "${MOCK_PR_MERGED:-yes}" == "yes" ]]; then
        [[ "$_jq" == *".oid"* ]] && echo "${MOCK_MERGE_SHA:-abcdef1234567890abcdef1234567890abcdef12}" || echo "{\"oid\":\"${MOCK_MERGE_SHA:-abcdef1234567890abcdef1234567890abcdef12}\"}"
      else echo "null"; fi ;;
    headRefOid) echo "${MOCK_PR_HEAD:-abcdef1234567890abcdef1234567890abcdef12}" ;;
    closingIssuesReferences) echo "${MOCK_CLOSING_ISSUES:-42}" ;;
  esac
  exit 0
fi
if [[ "${_ARGS[0]}" == "issue" && "${_ARGS[1]}" == "view" ]]; then
  if [[ "${MOCK_ISSUE_EXISTS:-no}" == "no" ]]; then echo "could not find issue" >&2; exit 1; fi
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

# Count lines matching both repo+issue AND pr patterns (two-stage grep)
count_matches() {
  local prog="$1" pat1="$2" pat2="$3"
  local n
  n=$(grep -F "$pat1" "$prog" 2>/dev/null | grep -Fc "$pat2" || true)
  echo "${n:-0}"
}

default_mock() {
  export MOCK_PR_EXISTS=yes MOCK_PR_MERGED=yes MOCK_ISSUE_STATE=CLOSED
  export MOCK_MERGE_SHA="$GOOD_HEAD" MOCK_PR_HEAD="$GOOD_HEAD"
  export MOCK_CLOSING_ISSUES="42" MOCK_ISSUE_EXISTS=yes
}

RUN() {
  bash "$TOOL" --repo "$1" --issue "$2" --worker "$3" --pr "$4" \
    --channel-root "$5" --expected-head "$6" --progress-file "$7" --result "$8" 2>&1
}

# ============================================================
echo "=== Original tests (adapted) ==="

echo "T1: green run"
PROG=$(setup_progress_file 1); setup_mock_gh; default_mock
OUT=$(RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "test green")
RC=$?
[ $RC -eq 0 ] && ok "exit 0" || ko "exit $RC: $OUT"
N=$(count_matches "$PROG" "munirad7s/test | #42" "PR #99")
[ "$N" -eq 1 ] && ok "one line" || ko "expected 1, got $N"
LINE=$(grep -F "munirad7s/test | #42" "$PROG" 2>/dev/null | grep "PR #99" || true)
echo "$LINE" | grep -q "| merge ${GOOD_HEAD:0:12} |" && ok "merge SHA" || ko "merge SHA wrong: [$LINE]"
echo "$LINE" | grep -q 'ch.b6037610a3e8' && ok "chan prefix" || ko "chan missing: [$LINE]"
echo "$LINE" | grep -q 'munirad7s/test' && ok "repo in line" || ko "repo missing: [$LINE]"

echo "T2: idempotency"
PROG=$(setup_progress_file 2); setup_mock_gh; default_mock
RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "test" >/dev/null 2>&1
N1=$(count_matches "$PROG" "munirad7s/test | #42" "PR #99")
OUT2=$(RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "test")
RC2=$?
N2=$(count_matches "$PROG" "munirad7s/test | #42" "PR #99")
[ "$N1" -eq 1 ] && [ "$N2" -eq 1 ] && ok "no dup" || ko "N1=$N1 N2=$N2"
[ $RC2 -eq 0 ] && ok "repeat exit 0" || ko "repeat exit $RC2"
echo "$OUT2" | grep -qi 'already' && ok "idem msg" || ko "no idem msg: $OUT2"

echo "T3: open PR -> exit 2"
PROG=$(setup_progress_file 3); setup_mock_gh
export MOCK_PR_MERGED=no MOCK_ISSUE_STATE=CLOSED
OUT3=$(RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "")
RC3=$?
[ $RC3 -eq 2 ] && ok "exit 2" || ko "expected 2, got $RC3: $OUT3"
N=$(count_matches "$PROG" "munirad7s/test | #42" "PR #99")
[ "$N" -eq 0 ] && ok "no line" || ko "line added"

echo "T4: open issue -> exit 3"
PROG=$(setup_progress_file 4); setup_mock_gh
export MOCK_PR_MERGED=yes MOCK_PR_HEAD="$GOOD_HEAD" MOCK_MERGE_SHA="$GOOD_HEAD" MOCK_ISSUE_STATE=OPEN MOCK_CLOSING_ISSUES=42
OUT4=$(RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "")
RC4=$?
[ $RC4 -eq 3 ] && ok "exit 3" || ko "expected 3, got $RC4: $OUT4"
N=$(count_matches "$PROG" "munirad7s/test | #42" "PR #99")
[ "$N" -eq 0 ] && ok "no line" || ko "line added"

echo "T5: nonexistent PR -> exit 4"
PROG=$(setup_progress_file 5); setup_mock_gh
export MOCK_PR_EXISTS=no MOCK_ISSUE_STATE=CLOSED
OUT5=$(RUN munirad7s/test 42 opencode-glm 999 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "")
RC5=$?
[ $RC5 -eq 4 ] && ok "exit 4" || ko "expected 4, got $RC5: $OUT5"
N=$(count_matches "$PROG" "munirad7s/test | #42" "PR #999")
[ "$N" -eq 0 ] && ok "no line" || ko "line added"

echo "T6: missing --expected-head -> exit 1"
PROG=$(setup_progress_file 6); setup_mock_gh; default_mock
OUT6=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root "$GOOD_CH" --progress-file "$PROG" 2>&1)
RC6=$?
[ $RC6 -eq 1 ] && ok "exit 1" || ko "expected 1, got $RC6: $OUT6"

# ============================================================
echo ""
echo "=== Gap 1: expected-head ==="

echo "T7: wrong head -> exit 6"
PROG=$(setup_progress_file 7); setup_mock_gh
export MOCK_PR_MERGED=yes MOCK_PR_HEAD="$GOOD_HEAD" MOCK_ISSUE_STATE=CLOSED MOCK_CLOSING_ISSUES=42
OUT7=$(RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$WRONG_HEAD" "$PROG" "")
RC7=$?
[ $RC7 -eq 6 ] && ok "exit 6" || ko "expected 6, got $RC7: $OUT7"
N=$(count_matches "$PROG" "munirad7s/test | #42" "PR #99")
[ "$N" -eq 0 ] && ok "no line" || ko "line added"

echo "T8: correct head -> exit 0"
PROG=$(setup_progress_file 8); setup_mock_gh; default_mock
OUT8=$(RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "")
RC8=$?
[ $RC8 -eq 0 ] && ok "exit 0" || ko "expected 0, got $RC8: $OUT8"

# ============================================================
echo ""
echo "=== Gap 2: closingIssuesReferences ==="

echo "T9: issue not in closing refs -> exit 7"
PROG=$(setup_progress_file 9); setup_mock_gh
export MOCK_PR_MERGED=yes MOCK_PR_HEAD="$GOOD_HEAD" MOCK_ISSUE_STATE=CLOSED MOCK_CLOSING_ISSUES="77"
OUT9=$(RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "")
RC9=$?
[ $RC9 -eq 7 ] && ok "exit 7" || ko "expected 7, got $RC9: $OUT9"
N=$(count_matches "$PROG" "munirad7s/test | #42" "PR #99")
[ "$N" -eq 0 ] && ok "no line" || ko "line added"

echo "T10: issue in closing refs -> exit 0"
PROG=$(setup_progress_file 10); setup_mock_gh
export MOCK_PR_MERGED=yes MOCK_PR_HEAD="$GOOD_HEAD" MOCK_ISSUE_STATE=CLOSED MOCK_CLOSING_ISSUES="42"
OUT10=$(RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "")
RC10=$?
[ $RC10 -eq 0 ] && ok "exit 0" || ko "expected 0, got $RC10: $OUT10"

# ============================================================
echo ""
echo "=== Gap 3: cross-repo idempotency ==="

echo "T11: two repos, same numbers -> both append"
PROG=$(setup_progress_file 11); setup_mock_gh; default_mock
RUN ownerA/repo-x 42 agent1 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "repo A" >/dev/null 2>&1
NA=$(count_matches "$PROG" "ownerA/repo-x | #42" "PR #99")
RUN ownerB/repo-y 42 agent1 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "repo B" >/dev/null 2>&1
NB=$(count_matches "$PROG" "ownerB/repo-y | #42" "PR #99")
[ "$NA" -eq 1 ] && [ "$NB" -eq 1 ] && ok "both repos independent" || ko "NA=$NA NB=$NB"

echo "T12: same repo repeat -> idempotent"
PROG=$(setup_progress_file 12); setup_mock_gh; default_mock
RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "test" >/dev/null 2>&1
RUN munirad7s/test 42 opencode-glm 99 "$GOOD_CH" "$GOOD_HEAD" "$PROG" "test" >/dev/null 2>&1
N=$(count_matches "$PROG" "munirad7s/test | #42" "PR #99")
[ "$N" -eq 1 ] && ok "exactly one" || ko "expected 1, got $N"

# ============================================================
echo ""
echo "=== Gap 4: input validation ==="

echo "T13: non-numeric issue -> exit 1"
PROG=$(setup_progress_file 13); setup_mock_gh; default_mock
OUT13=$(bash "$TOOL" --repo munirad7s/test --issue abc --worker opencode-glm --pr 99 \
  --channel-root "$GOOD_CH" --expected-head "$GOOD_HEAD" --progress-file "$PROG" 2>&1)
[ $? -eq 1 ] && ok "exit 1" || ko "expected 1: $OUT13"

echo "T14: non-numeric PR -> exit 1"
PROG=$(setup_progress_file 14); setup_mock_gh; default_mock
OUT14=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr xyz \
  --channel-root "$GOOD_CH" --expected-head "$GOOD_HEAD" --progress-file "$PROG" 2>&1)
[ $? -eq 1 ] && ok "exit 1" || ko "expected 1: $OUT14"

echo "T15: short channel-root -> exit 1"
PROG=$(setup_progress_file 15); setup_mock_gh; default_mock
OUT15=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root "abcd" --expected-head "$GOOD_HEAD" --progress-file "$PROG" 2>&1)
[ $? -eq 1 ] && ok "exit 1" || ko "expected 1: $OUT15"

echo "T16: short expected-head -> exit 1"
PROG=$(setup_progress_file 16); setup_mock_gh; default_mock
OUT16=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root "$GOOD_CH" --expected-head "abc" --progress-file "$PROG" 2>&1)
[ $? -eq 1 ] && ok "exit 1" || ko "expected 1: $OUT16"

echo "T17: worker with pipe -> exit 1"
PROG=$(setup_progress_file 17); setup_mock_gh; default_mock
OUT17=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker "evil|worker" --pr 99 \
  --channel-root "$GOOD_CH" --expected-head "$GOOD_HEAD" --progress-file "$PROG" 2>&1)
[ $? -eq 1 ] && ok "exit 1" || ko "expected 1: $OUT17"

echo "T18: result with newline -> exit 1"
PROG=$(setup_progress_file 18); setup_mock_gh; default_mock
OUT18=$(bash "$TOOL" --repo munirad7s/test --issue 42 --worker opencode-glm --pr 99 \
  --channel-root "$GOOD_CH" --expected-head "$GOOD_HEAD" \
  --result $'line1\nline2' --progress-file "$PROG" 2>&1)
[ $? -eq 1 ] && ok "exit 1" || ko "expected 1: $OUT18"

echo "T19: bad repo format -> exit 1"
PROG=$(setup_progress_file 19); setup_mock_gh; default_mock
OUT19=$(bash "$TOOL" --repo "not-a-repo" --issue 42 --worker opencode-glm --pr 99 \
  --channel-root "$GOOD_CH" --expected-head "$GOOD_HEAD" --progress-file "$PROG" 2>&1)
[ $? -eq 1 ] && ok "exit 1" || ko "expected 1: $OUT19"

# ============================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -gt 0 ] && exit 1
exit 0
