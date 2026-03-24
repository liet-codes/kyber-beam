# Secrets & Trust Boundaries

*Design doc — ported from TypeScript kyber repo (2026-03-16). Adapted for Elixir/OTP.*

> See also: SECURITY_AUDIT.md for the full audit of current implementation gaps.

## Problem

Kyber's agent needs secrets (API tokens, service credentials) to function. But the LLM — the component most likely to leak, be prompt-injected, or reason about its own capabilities — should never see secret values. We need secrets to be **usable but opaque** from the agent's perspective.

## Threat Model

| Threat | Likelihood | Severity | Mitigation |
|--------|-----------|----------|------------|
| **T1: Accidental leakage** — secret ends up in LLM context, gets logged in delta log, echoed in conversation | High | High | Secret references, never values in context |
| **T2: Prompt injection** — external Discord input causes agent to attempt exfiltration | Medium | High | LLM never holds values; effect validation layer |
| **T3: Autonomous exfiltration** — agent reasons about its constraints and works around them | Low | Critical | Audit trail; BEAM process isolation for high-risk contexts |

T1 is the primary target. T2 is real and growing (C-1 in SECURITY_AUDIT.md confirms shell exec is currently unrestricted). T3 is acknowledged — full prevention requires physical isolation, which has tradeoffs.

## Design: Secret References at the Effect Boundary

### Core Principle

Secrets resolve **at the effect executor** (`Kyber.Effect.Executor`), never in the reducer, never in the LLM context, never in the delta log. The LLM works with opaque handles.

```
LLM receives:      "You have access to the Anthropic API"
LLM emits:         %{kind: "llm_call", model: "haiku"}
Effect Executor:   resolves "llm.anthropic.token" → actual value
HTTP call:         made with real credentials
Delta logged:      response content only, no credentials
```

### Secret Store Interface

```elixir
@callback resolve(name :: String.t()) :: {:ok, String.t()} | {:error, term()}
@callback exists?(name :: String.t()) :: boolean()
@callback list() :: [String.t()]  # names only, never values
```

Pluggable backends. Start with one, swap later without touching plugins.

**Backend options:**

| Backend | Pros | Cons | When |
|---------|------|------|------|
| macOS Keychain (via `security` CLI) | Native, encrypted, zero deps | Mac-only | Phase 1 (dev) |
| `.env` file + `System.get_env/1` | Simplest | No encryption at rest | Current approach |
| age-encrypted file | Portable, git-safe | Manual rotation | Phase 1 (deploy) |
| SOPS | Structured YAML/JSON, multiple KMS backends | Extra dep | Phase 2 |
| Infisical | OSS, rotation, audit, teams | Server component | Phase 3+ |

> **Current state:** Secrets are loaded from `.env` via `System.get_env/1` on startup. The `.env` file must not be committed to git. This is acceptable for single-user local deployment but should move to Keychain or age-encrypted file for any shared or deployed instance.

### Plugin Manifests Declare Secret Scopes

Each plugin declares what secrets it needs upfront (in its module or config):

```elixir
defmodule Kyber.Plugin.LLM do
  @secrets ["llm.anthropic.token", "llm.anthropic.token.staging"]
  @capabilities [:network]
  @trust :verified
end
```

The secret store enforces scoping: a plugin can only resolve secrets matching its declared names. This is **least-privilege by convention** in Phase 1, enforceable by namespace in Phase 2.

### Namespace Convention

Secret names mirror plugin paths: `{plugin}.{service}.{key}[.{environment}]`

```
llm.anthropic.token
llm.anthropic.token.staging
tts.elevenlabs.key
channel.discord.token
channel.discord.token.dev
```

A plugin requesting `channel.discord.token` from within the `llm` plugin gets rejected — wrong namespace.

### Error Sanitization

API client libraries often include auth headers in error messages. The effect executor **must** sanitize errors before emitting error deltas. This was implemented in PR #6.

```elixir
defmodule Kyber.Effect.ErrorSanitizer do
  @doc "Strip known secret values from error messages before logging as deltas"
  def sanitize(message, secrets) do
    Enum.reduce(secrets, message, fn secret, acc ->
      String.replace(acc, secret, "[REDACTED]")
    end)
  end
end
```

This is the most commonly missed vector. Even with perfect reference indirection, a leaked error string can expose credentials.

### What the Agent CAN Know

- Secret names (for routing decisions)
- Whether a secret exists (for graceful degradation)
- Last-rotated timestamp (for health monitoring)
- Which backend is active (for diagnostics)

### What the Agent NEVER Sees

- Secret values
- Partial values (prefixes, suffixes, lengths)
- Encrypted blobs
- Backend-specific storage details

## Trust Rings and Secret Access

Trust rings (from tool-system.md) map directly to secret access levels:

| Ring | Secret Access |
|------|--------------|
| 0 (Builtin) | Full access to all secrets via direct resolver |
| 1 (Verified) | Access to secrets declared in plugin manifest |
| 2 (Community) | No direct secret access; proxy/approval required |
| 3 (Untrusted) | No secret access whatsoever |

## Why Not BEAM Process Isolation (and When to Reconsider)

The BEAM's process model offers excellent isolation compared to traditional thread-based systems. Running LLM inference in an isolated process with restricted message passing is cleaner than Docker containers.

**The clean version of BEAM isolation:**

```
┌─── Kyber.Core (privileged process) ──────────────────┐
│  Delta store, reducer, plugins                        │
│  Effect executor (resolves secrets)                   │
│  Secret store                                         │
│                                                       │
│  ┌─── Kyber.LLM.Sandbox (isolated process) ────────┐ │
│  │  Receives: messages + tool definitions           │ │
│  │  Returns: text + tool calls                      │ │
│  │  Has: no secret access, no direct I/O            │ │
│  └──────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────┘
```

**Why we're not doing this (yet):**

1. **Capability loss.** The whole point of agents is autonomous action. Every capability you remove from the LLM's reach requires explicit host-side mediation. At some point you're building a chatbot with extra steps.

2. **Streaming.** Streaming responses for Discord (live editing) requires tight coupling between LLM output and Discord API calls. A message-passing boundary adds complexity here.

3. **Context assembly.** The host must serialize complete context into the isolated process each call. Lazy vault loading (`L1 → L2 on demand`) becomes an expensive round-trip.

4. **Development ergonomics.** Single-node dev is fast. Process isolation for LLM adds complexity in hot-reload and debugging.

**The decision:** Trust boundaries enforced **at the effect executor** (pattern already in place), with secret references and error sanitization. This handles T1 completely and most of T2. The architecture is designed so that process isolation can be added later for specific high-risk contexts.

**When to reconsider:**
- Third-party/untrusted plugins that we can't audit (Ring 3 tools)
- Multi-user deployment (multiple humans, one Kyber instance)
- Processing hostile input at scale (public-facing bot)
- Regulatory/compliance requirements

## Current Gaps (from SECURITY_AUDIT.md)

Critical issues that need addressing (see full audit for details):

- **C-1:** `exec` tool passes LLM-generated commands directly to `sh -c` — no denylist, no allowlist. Prompt injection via Discord → LLM → exec is a real attack surface.
- **C-2:** Bearer auth token in HTTP Authorization header (may appear in error logs from HTTP clients).
- **C-3/C-4:** Additional critical items detailed in SECURITY_AUDIT.md.

Fixing C-1 is the highest priority: add a configurable allowlist or require human approval for `exec` calls from non-trusted origins.

## Implementation Phases

### Phase 1 (Current): References + Env Vars
- Secrets loaded from `.env` at startup via `System.get_env/1`
- Effect executor resolves refs at call time (not in LLM context)
- Error sanitization on API client wrappers ✓ (PR #6)
- `kyber secret set llm.anthropic.token <value>` helper script

### Phase 2: Enforcement + Audit
- Namespace enforcement (plugins can't cross-request)
- Audit log for all secret resolutions (who, when, which ref)
- Keychain backend for macOS (via `security` CLI)
- Rotation support (resolve returns latest version)
- Fix exec tool: add configurable command allowlist

### Phase 3: Selective Isolation (if needed)
- BEAM process isolation option for specific plugins
- Host-side secret proxy for isolated workloads
- Trust-level configuration per subagent
- Different sandbox strictness for different input sources

## Connection to Other Design Docs

- **Principles** (design-principles.md): Implements Principle 3 (Boundaries at the Effect Executor) and Principle 4 (Sovereignty Over Convenience).
- **Tools** (tool-system.md): Tool manifests declare secret scopes using the namespace convention defined here. Trust rings map to secret access levels.
- **Observability** (observability.md): Secret resolution events are tracked in DeltaMeta (who resolved what, when). Error sanitization strips values before they reach delta payloads.

---

*The agent holds the map. The executor holds the keys. The map never shows where the keys are hidden.*
