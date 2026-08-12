#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resolver="$repo_root/scripts/resolve-pnpm-cache-path.sh"
workflow="$repo_root/.github/workflows/ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/pnpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${FAKE_PNPM_MODE:?}" in
  valid)
    printf '%s\n' '/tmp/pnpm/store/v11'
    ;;
  retry)
    count=0
    if [[ -f "${FAKE_PNPM_COUNT:?}" ]]; then
      count="$(cat "$FAKE_PNPM_COUNT")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_PNPM_COUNT"
    if [[ "$count" -lt 3 ]]; then
      exit 1
    fi
    printf '%s\n' '/tmp/pnpm/store/v11'
    ;;
  failure)
    exit 1
    ;;
  empty)
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$tmp/bin/pnpm"

run_resolver() {
  local mode="$1"
  : >"$tmp/github-output"
  rm -f "$tmp/pnpm-count"
  PATH="$tmp/bin:$PATH" \
    FAKE_PNPM_MODE="$mode" \
    FAKE_PNPM_COUNT="$tmp/pnpm-count" \
    GITHUB_OUTPUT="$tmp/github-output" \
    PNPM_STORE_PATH_RETRY_DELAY=0 \
    bash "$resolver" >"$tmp/resolver-log" 2>&1
}

run_resolver valid
grep -Fxq 'available=true' "$tmp/github-output"
grep -Fxq 'STORE_PATH=/tmp/pnpm/store/v11' "$tmp/github-output"

run_resolver retry
grep -Fxq '3' "$tmp/pnpm-count"
grep -Fxq 'available=true' "$tmp/github-output"
grep -Fxq 'STORE_PATH=/tmp/pnpm/store/v11' "$tmp/github-output"

for mode in failure empty; do
  run_resolver "$mode"
  grep -Fxq 'available=false' "$tmp/github-output"
  if grep -Fq 'STORE_PATH=' "$tmp/github-output"; then
    echo "$mode resolver output exposed an empty cache path" >&2
    exit 1
  fi
done

[[ "$(grep -Fc 'run: bash scripts/resolve-pnpm-cache-path.sh' "$workflow")" -eq 4 ]]
[[ "$(grep -Fc "        if: steps.pnpm-cache.outputs.available == 'true'" "$workflow")" -eq 4 ]]
[[ "$(grep -Fc "        if: github.event_name == 'push' && steps.pnpm-cache.outputs.available == 'true'" "$workflow")" -eq 3 ]]
[[ "$(grep -Fc 'path: ${{ steps.pnpm-cache.outputs.STORE_PATH }}' "$workflow")" -eq 7 ]]
grep -Fq 'bash scripts/test-ci-pnpm-cache-contract.sh' "$workflow"

if grep -Fq 'pnpm store path' "$workflow"; then
  echo 'ci.yml must resolve pnpm cache paths through the guarded helper' >&2
  exit 1
fi

echo 'pnpm cache workflow contract passed'
