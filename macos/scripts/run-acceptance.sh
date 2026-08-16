#!/usr/bin/env bash
# Two-user acceptance run for the native macOS client (WINL-12).
#
# Verifies a live server is reachable, then drives two full client stacks
# through friend requests, presence, bidirectional messaging, typing,
# delivered/read receipts, forced reconnect, and history convergence.
#
# Usage:
#   macos/scripts/run-acceptance.sh                     # http://127.0.0.1:3100
#   PENGUINCHAT_API_URL=http://127.0.0.1:3000 macos/scripts/run-acceptance.sh
#
# The harness registers throwaway users per run and keeps their tokens in
# memory only, so it never touches the app's Keychain item and leaves no
# credentials on disk.

set -euo pipefail

API_URL="${PENGUINCHAT_API_URL:-http://127.0.0.1:3100}"
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../PenguinChatMac" && pwd)"

echo "checking ${API_URL}/health"
if ! curl -fsS --max-time 5 "${API_URL}/health" >/dev/null 2>&1; then
  echo "error: no healthy server at ${API_URL}" >&2
  echo "start one with: docker compose up -d api" >&2
  echo "or override the target with PENGUINCHAT_API_URL" >&2
  exit 1
fi

cd "$PACKAGE_DIR"
PENGUINCHAT_API_URL="$API_URL" swift run AcceptanceHarness
