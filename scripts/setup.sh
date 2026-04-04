#!/usr/bin/env bash
# scripts/setup.sh — Turnkey setup for kyber-beam on a fresh macOS machine.
#
# Usage:
#   ./scripts/setup.sh                            # full install
#   ./scripts/setup.sh --import-openclaw <zip>     # install + import OpenClaw vault
#   ./scripts/setup.sh --import-kyber <zip>        # install + import existing Kyber vault
#
# Requirements: macOS (detects and fails gracefully on other OSes)

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[kyber]${NC} $*"; }
success() { echo -e "${GREEN}[kyber]${NC} $*"; }
warn()    { echo -e "${YELLOW}[kyber]${NC} $*"; }
error()   { echo -e "${RED}[kyber]${NC} $*" >&2; }
step()    { echo -e "\n${CYAN}${BOLD}── $* ──${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
KYBER_HOME="${HOME}/.kyber"
VAULT_DIR="${KYBER_HOME}/vault"

# ── OS check ───────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Darwin" ]]; then
  error "This script is designed for macOS."
  echo ""
  echo "  On Linux, install manually:"
  echo "    1. Install Erlang/OTP 26+ and Elixir 1.14+ (via asdf or package manager)"
  echo "    2. Install Node.js 18+ (via nvm or package manager)"
  echo "    3. cd $REPO_DIR && mix deps.get && mix compile"
  echo "    4. cd priv/agent-sdk && npm install"
  echo "    5. mkdir -p ~/.kyber/vault"
  echo ""
  exit 1
fi

# ── Parse flags ────────────────────────────────────────────────────────────
IMPORT_OPENCLAW=""
IMPORT_KYBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --import-openclaw)
      if [[ -z "${2:-}" ]]; then
        error "--import-openclaw requires a zip file path"
        exit 1
      fi
      IMPORT_OPENCLAW="$2"
      shift 2
      ;;
    --import-kyber)
      if [[ -z "${2:-}" ]]; then
        error "--import-kyber requires a zip file path"
        exit 1
      fi
      IMPORT_KYBER="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--import-openclaw <zip>] [--import-kyber <zip>]"
      exit 0
      ;;
    *)
      error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate import paths early
if [[ -n "$IMPORT_OPENCLAW" && ! -f "$IMPORT_OPENCLAW" ]]; then
  error "OpenClaw zip not found: $IMPORT_OPENCLAW"
  exit 1
fi
if [[ -n "$IMPORT_KYBER" && ! -f "$IMPORT_KYBER" ]]; then
  error "Kyber zip not found: $IMPORT_KYBER"
  exit 1
fi

# ── 1. Homebrew ────────────────────────────────────────────────────────────
step "Checking Homebrew"

if command -v brew &>/dev/null; then
  success "Homebrew found: $(brew --prefix)"
else
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add brew to PATH for Apple Silicon
  if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi

  success "Homebrew installed"
fi

# ── 2. asdf (version manager) ─────────────────────────────────────────────
step "Checking asdf"

if command -v asdf &>/dev/null; then
  success "asdf found: $(asdf version 2>/dev/null || echo 'installed')"
else
  info "Installing asdf via Homebrew..."
  brew install asdf

  # Source asdf for current session
  if [[ -f "$(brew --prefix asdf)/libexec/asdf.sh" ]]; then
    # shellcheck disable=SC1091
    . "$(brew --prefix asdf)/libexec/asdf.sh"
  fi

  success "asdf installed"
fi

# ── 3. Erlang ──────────────────────────────────────────────────────────────
step "Checking Erlang"

if command -v erl &>/dev/null; then
  ERL_VERSION=$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "unknown")
  success "Erlang OTP $ERL_VERSION found"
else
  info "Installing Erlang..."
  if command -v asdf &>/dev/null; then
    asdf plugin add erlang 2>/dev/null || true
    # Install required build deps
    brew install autoconf openssl wxwidgets libxslt fop 2>/dev/null || true
    LATEST_ERLANG=$(asdf latest erlang 2>/dev/null || echo "27.2")
    info "Installing Erlang $LATEST_ERLANG via asdf (this takes a while)..."
    asdf install erlang "$LATEST_ERLANG"
    asdf global erlang "$LATEST_ERLANG"
  else
    info "Falling back to Homebrew..."
    brew install erlang
  fi
  success "Erlang installed"
fi

# ── 4. Elixir ──────────────────────────────────────────────────────────────
step "Checking Elixir"

if command -v elixir &>/dev/null; then
  ELIXIR_VERSION=$(elixir --version | grep "Elixir" | head -1)
  success "$ELIXIR_VERSION found"
else
  info "Installing Elixir..."
  if command -v asdf &>/dev/null; then
    asdf plugin add elixir 2>/dev/null || true
    LATEST_ELIXIR=$(asdf latest elixir 2>/dev/null || echo "1.17.3-otp-27")
    info "Installing Elixir $LATEST_ELIXIR via asdf..."
    asdf install elixir "$LATEST_ELIXIR"
    asdf global elixir "$LATEST_ELIXIR"
  else
    info "Falling back to Homebrew..."
    brew install elixir
  fi
  success "Elixir installed"
fi

# ── 5. Node.js (for Agent SDK bridge) ─────────────────────────────────────
step "Checking Node.js"

if command -v node &>/dev/null; then
  NODE_VERSION=$(node --version)
  success "Node.js $NODE_VERSION found"
else
  info "Installing Node.js..."
  if command -v asdf &>/dev/null; then
    asdf plugin add nodejs 2>/dev/null || true
    LATEST_NODE=$(asdf latest nodejs 22 2>/dev/null || echo "22.12.0")
    info "Installing Node.js $LATEST_NODE via asdf..."
    asdf install nodejs "$LATEST_NODE"
    asdf global nodejs "$LATEST_NODE"
  else
    info "Falling back to Homebrew..."
    brew install node
  fi
  success "Node.js installed"
fi

# ── 6. Elixir dependencies ────────────────────────────────────────────────
step "Installing Elixir dependencies"

cd "$REPO_DIR"

info "Running mix local.hex --force..."
mix local.hex --force >/dev/null 2>&1

info "Running mix local.rebar --force..."
mix local.rebar --force >/dev/null 2>&1

info "Running mix deps.get..."
mix deps.get

info "Compiling..."
mix compile

success "Elixir dependencies installed and compiled"

# ── 7. Agent SDK bridge dependencies ──────────────────────────────────────
step "Installing Agent SDK bridge"

AGENT_SDK_DIR="${REPO_DIR}/priv/agent-sdk"
if [[ -f "${AGENT_SDK_DIR}/package.json" ]]; then
  cd "$AGENT_SDK_DIR"
  info "Running npm install..."
  npm install
  success "Agent SDK bridge dependencies installed"
else
  warn "Agent SDK bridge not found at ${AGENT_SDK_DIR} -- skipping"
fi

# ── 8. Default config ─────────────────────────────────────────────────────
step "Setting up ~/.kyber"

mkdir -p "$VAULT_DIR"
mkdir -p "${KYBER_HOME}/logs"

if [[ ! -f "${KYBER_HOME}/config.env" ]]; then
  cat > "${KYBER_HOME}/config.env" <<'ENVEOF'
# Kyber-BEAM configuration
# Uncomment and set values as needed.

# Discord bot token (required for Discord integration)
# DISCORD_BOT_TOKEN=your_token_here

# Anthropic API key (if not using OAuth)
# ANTHROPIC_API_KEY=sk-ant-api-...

# Brave Search API key (for web_search tool)
# BRAVE_SEARCH_API_KEY=

# LLM backend: "api" (direct Anthropic API) or "agent_sdk" (Claude Agent SDK)
# KYBER_LLM_BACKEND=api
ENVEOF
  success "Created default config at ${KYBER_HOME}/config.env"
else
  info "Config already exists at ${KYBER_HOME}/config.env"
fi

# ── 9. Import: OpenClaw ───────────────────────────────────────────────────
if [[ -n "$IMPORT_OPENCLAW" ]]; then
  step "Importing OpenClaw vault"

  TMPDIR_IMPORT=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_IMPORT"' EXIT

  info "Extracting $IMPORT_OPENCLAW..."
  unzip -o -q "$IMPORT_OPENCLAW" -d "$TMPDIR_IMPORT"

  # Detect vault layout: multi-agent if agents/ or shared/ exists
  if [[ -d "${VAULT_DIR}/agents" || -d "${VAULT_DIR}/shared" ]]; then
    AGENT_NAME="${OPENCLAW_AGENT_NAME:-liet}"
    AGENT_DIR="${VAULT_DIR}/agents/${AGENT_NAME}"
    SHARED_DIR="${VAULT_DIR}/shared"
    mkdir -p "$AGENT_DIR/memory" "$SHARED_DIR"/{concepts,people,projects}

    info "Multi-agent layout detected (agent: ${AGENT_NAME})"

    # Identity files to agent dir
    for f in SOUL.md MEMORY.md TOOLS.md IDENTITY.md AGENTS.md; do
      found=$(find "$TMPDIR_IMPORT" -name "$f" -type f | head -1)
      if [[ -n "$found" ]]; then
        cp "$found" "$AGENT_DIR/$f"
        success "  Imported $f -> agents/${AGENT_NAME}/$f"
      fi
    done

    # USER.md to shared (same human for both agents)
    found_user=$(find "$TMPDIR_IMPORT" -name "USER.md" -type f | head -1)
    if [[ -n "$found_user" ]]; then
      cp "$found_user" "$SHARED_DIR/USER.md"
      success "  Imported USER.md -> shared/USER.md"
    fi

    # Memory files to agent memory dir
    memory_src=$(find "$TMPDIR_IMPORT" -type d -name "memory" | head -1)
    if [[ -n "$memory_src" ]]; then
      find "$memory_src" -name "*.md" -type f | while read -r mf; do
        basename_f=$(basename "$mf")
        cp "$mf" "$AGENT_DIR/memory/$basename_f"
        success "  Imported memory/$basename_f -> agents/${AGENT_NAME}/memory/$basename_f"
      done
    fi

    # Shared dirs: concepts, people, projects
    for dir_name in concepts people projects; do
      dir_src=$(find "$TMPDIR_IMPORT" -type d -name "$dir_name" | head -1)
      if [[ -n "$dir_src" ]]; then
        find "$dir_src" -name "*.md" -type f | while read -r sf; do
          basename_f=$(basename "$sf")
          cp "$sf" "$SHARED_DIR/$dir_name/$basename_f"
          success "  Imported $dir_name/$basename_f -> shared/$dir_name/$basename_f"
        done
      fi
    done

    success "OpenClaw import complete -> ${VAULT_DIR} (agent: ${AGENT_NAME})"
  else
    # Legacy layout
    IDENTITY_DIR="${VAULT_DIR}/identity"
    MEMORY_DIR="${VAULT_DIR}/memory"
    mkdir -p "$IDENTITY_DIR" "$MEMORY_DIR"

    for f in SOUL.md MEMORY.md USER.md TOOLS.md IDENTITY.md; do
      found=$(find "$TMPDIR_IMPORT" -name "$f" -type f | head -1)
      if [[ -n "$found" ]]; then
        cp "$found" "$IDENTITY_DIR/$f"
        success "  Imported $f -> identity/$f"
      else
        warn "  $f not found in archive"
      fi
    done

    memory_src=$(find "$TMPDIR_IMPORT" -type d -name "memory" | head -1)
    if [[ -n "$memory_src" ]]; then
      find "$memory_src" -name "*.md" -type f | while read -r mf; do
        basename_f=$(basename "$mf")
        cp "$mf" "$MEMORY_DIR/$basename_f"
        success "  Imported memory/$basename_f"
      done
    else
      warn "  No memory/ directory found in archive"
    fi

    success "OpenClaw import complete -> ${VAULT_DIR}"
  fi
fi

# ── 10. Import: Kyber vault ───────────────────────────────────────────────
if [[ -n "$IMPORT_KYBER" ]]; then
  step "Importing Kyber vault"

  if [[ -d "${VAULT_DIR}/agents" || -d "${VAULT_DIR}/shared" ]]; then
    AGENT_NAME="${KYBER_AGENT_NAME:-stilgar}"
    info "Multi-agent layout detected -- importing via mix task (agent: ${AGENT_NAME})"
    cd "$REPO_DIR"
    mix kyber.import.kyber "$IMPORT_KYBER" --agent-name "$AGENT_NAME"
  else
    info "Extracting $IMPORT_KYBER -> ${VAULT_DIR}..."
    mkdir -p "$VAULT_DIR"
    unzip -o -q "$IMPORT_KYBER" -d "$VAULT_DIR"
  fi

  success "Kyber vault import complete -> ${VAULT_DIR}"
fi

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}+======================================================+${NC}"
echo -e "${GREEN}${BOLD}|          kyber-beam setup complete!                   |${NC}"
echo -e "${GREEN}${BOLD}+======================================================+${NC}"
echo ""
echo -e "  ${BOLD}To start kyber-beam:${NC}"
echo ""
echo -e "    ${CYAN}cd $REPO_DIR${NC}"
echo -e "    ${CYAN}cp .env.example .env  ${NC}${YELLOW}# add your DISCORD_BOT_TOKEN${NC}"
echo -e "    ${CYAN}mix run --no-halt${NC}"
echo ""
echo -e "  ${BOLD}Or use the start script:${NC}"
echo -e "    ${CYAN}./scripts/start.sh${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC} http://localhost:4001"
echo ""
echo -e "  ${BOLD}Config:${NC} ${KYBER_HOME}/config.env"
echo -e "  ${BOLD}Vault:${NC}  ${VAULT_DIR}"
echo ""
echo -e "  ${BOLD}Agent SDK backend:${NC}"
echo -e "    Set ${CYAN}KYBER_LLM_BACKEND=agent_sdk${NC} in .env to use Claude Agent SDK"
echo -e "    (requires Claude CLI auth at ~/.claude/)"
echo ""
