#!/usr/bin/env bash
# scripts/start.sh — Start kyber-beam with env loaded from .env file.
#
# Usage:
#   ./scripts/start.sh           # foreground (interactive dev)
#   ./scripts/start.sh --daemon  # nohup background (for manual use)
#
# Environment variables:
#   DISCORD_BOT_TOKEN — required. Set in .env or export before running.
#
# The launchd plist (com.liet.kyber-beam.plist) calls this script directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${REPO_DIR}/.env"
LOG_DIR="${HOME}/.kyber/logs"

# ── Load .env if present ─────────────────────────────────────────────────────
if [[ -f "${ENV_FILE}" ]]; then
  # Export all non-comment, non-empty lines
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

# ── Validate required vars ────────────────────────────────────────────────────
if [[ -z "${DISCORD_BOT_TOKEN:-}" ]]; then
  echo "[kyber-beam] ERROR: DISCORD_BOT_TOKEN is not set." >&2
  echo "  Create ${REPO_DIR}/.env with: DISCORD_BOT_TOKEN=your_token_here" >&2
  exit 1
fi

# ── Ensure log directory exists ───────────────────────────────────────────────
mkdir -p "${LOG_DIR}"

# ── Run ───────────────────────────────────────────────────────────────────────
cd "${REPO_DIR}"

if [[ "${1:-}" == "--daemon" ]]; then
  echo "[kyber-beam] Starting in background. Logs: ${LOG_DIR}"
  nohup mix run --no-halt \
    >> "${LOG_DIR}/kyber-beam.log" \
    2>> "${LOG_DIR}/kyber-beam-error.log" \
    &
  echo "[kyber-beam] PID: $!"
else
  exec mix run --no-halt
fi
