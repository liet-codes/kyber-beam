#!/usr/bin/env bash
# scripts/install.sh — Install the kyber-beam launchd plist.
#
# This installs com.liet.kyber-beam.plist to ~/Library/LaunchAgents/
# and optionally loads it immediately.
#
# Usage:
#   ./scripts/install.sh          # install + load (autostart on login)
#   ./scripts/install.sh --unload # unload + remove

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PLIST_SRC="${REPO_DIR}/com.liet.kyber-beam.plist"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
PLIST_DEST="${LAUNCH_AGENTS}/com.liet.kyber-beam.plist"
LOG_DIR="${HOME}/.kyber/logs"
LABEL="com.liet.kyber-beam"

# ── Validate .env exists ──────────────────────────────────────────────────────
ENV_FILE="${REPO_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[install] WARNING: ${ENV_FILE} not found."
  echo "  Create it with your DISCORD_BOT_TOKEN before the service starts:"
  echo "  echo 'DISCORD_BOT_TOKEN=your_token_here' > ${ENV_FILE}"
  echo ""
fi

# ── Unload mode ───────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--unload" ]]; then
  echo "[install] Unloading ${LABEL}..."
  launchctl unload "${PLIST_DEST}" 2>/dev/null || true
  rm -f "${PLIST_DEST}"
  echo "[install] Done. Service removed."
  exit 0
fi

# ── Pre-flight ────────────────────────────────────────────────────────────────
if [[ ! -f "${PLIST_SRC}" ]]; then
  echo "[install] ERROR: plist not found at ${PLIST_SRC}" >&2
  exit 1
fi

mkdir -p "${LAUNCH_AGENTS}"
mkdir -p "${LOG_DIR}"

# ── Unload any existing instance ─────────────────────────────────────────────
if launchctl list "${LABEL}" &>/dev/null; then
  echo "[install] Unloading existing service..."
  launchctl unload "${PLIST_DEST}" 2>/dev/null || true
fi

# ── Install ───────────────────────────────────────────────────────────────────
cp "${PLIST_SRC}" "${PLIST_DEST}"
echo "[install] Installed: ${PLIST_DEST}"

# ── Load ──────────────────────────────────────────────────────────────────────
launchctl load "${PLIST_DEST}"
echo "[install] Service loaded. kyber-beam will start now and on every login."
echo ""
echo "  Logs:   ${LOG_DIR}/kyber-beam.log"
echo "  Errors: ${LOG_DIR}/kyber-beam-error.log"
echo ""
echo "  Stop:   launchctl unload ~/Library/LaunchAgents/com.liet.kyber-beam.plist"
echo "  Start:  launchctl load ~/Library/LaunchAgents/com.liet.kyber-beam.plist"
echo "  Remove: ./scripts/install.sh --unload"
