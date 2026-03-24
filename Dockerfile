# =============================================================================
# kyber-beam production Dockerfile
# Multi-stage: builder (compile + release) → runner (minimal runtime)
# =============================================================================

# --- Stage 1: Builder --------------------------------------------------------
FROM hexpm/elixir:1.16.3-erlang-26.2.5-debian-bookworm-20240701-slim AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

# Install build tools (git for potential git deps)
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install hex + rebar (layer cached unless Elixir version changes)
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency manifests first for layer caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

# Copy config (needed before compile for config-time settings)
COPY config config

# Copy application source
COPY lib lib
COPY priv priv

# Compile and build release
RUN mix compile && mix release

# --- Stage 2: Runner ---------------------------------------------------------
FROM debian:bookworm-slim AS runner

ENV LANG=C.UTF-8 \
    MIX_ENV=prod

# Install minimal runtime deps (OpenSSL for crypto, libncurses for BEAM)
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses5 locales curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-root user
RUN groupadd --system kyber && \
    useradd --system --gid kyber --home /app --shell /bin/sh kyber

WORKDIR /app

# Copy release from builder
COPY --from=builder --chown=kyber:kyber /app/_build/prod/rel/kyber_beam ./

USER kyber

# Expose the Plug API port (4000) and Phoenix dashboard port (4001)
EXPOSE 4000 4001

# Health check against the Plug router /health endpoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:4000/health || exit 1

ENTRYPOINT ["bin/kyber_beam"]
CMD ["start"]
