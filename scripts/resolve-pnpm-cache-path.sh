#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

attempts=3
retry_delay="${PNPM_STORE_PATH_RETRY_DELAY:-2}"

for ((attempt = 1; attempt <= attempts; attempt++)); do
  if store_path="$(pnpm store path --silent)"; then
    store_path="${store_path%$'\r'}"
    if [[ -n "${store_path//[[:space:]]/}" && "$store_path" == /* && "$store_path" != *$'\n'* ]]; then
      printf 'available=true\nSTORE_PATH=%s\n' "$store_path" >>"$GITHUB_OUTPUT"
      exit 0
    fi
    echo "::warning::pnpm returned an invalid store path on attempt $attempt/$attempts"
  else
    echo "::warning::pnpm store path failed on attempt $attempt/$attempts"
  fi

  if [[ "$attempt" -lt "$attempts" ]]; then
    sleep "$retry_delay"
  fi
done

printf 'available=false\n' >>"$GITHUB_OUTPUT"
echo '::warning::Continuing without the optional pnpm store cache; dependency installation remains required.'
