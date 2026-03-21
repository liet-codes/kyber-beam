#!/bin/bash
# Kyber-BEAM launcher for launchd
# Uses Homebrew Erlang 28.4.1 (has :re.import/1) + asdf Elixir

export HOME="/Users/liet"
export LANG=en_US.UTF-8
export MIX_ENV=dev

# Homebrew Erlang (28.4.1, erts-16.3) — has :re.import/1 restored
# asdf Erlang 28.0 (erts-16.0) does NOT have it
ERLANG_ROOT="/usr/local/Cellar/erlang/28.4.1/lib/erlang"
ELIXIR_ROOT="/Users/liet/.asdf/installs/elixir/1.19.5"

export PATH="${ELIXIR_ROOT}/bin:${ERLANG_ROOT}/bin:/usr/local/bin:/usr/bin:/bin"
export MIX_HOME="${ELIXIR_ROOT}/.mix"

cd /Users/liet/kyber-beam

# Source environment variables (DISCORD_BOT_TOKEN, etc.)
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

exec elixir --no-halt -S mix run
