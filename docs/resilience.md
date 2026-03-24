# Resilience & Recovery

*Design doc — ported from TypeScript kyber repo (2026-03-16). Adapted for Elixir/OTP.*

Kyber-beam should be hard to kill and easy to fix. The BEAM gives us much of this for free — but we still need to think carefully about error handling, supervision, and recovery.

## 1. The BEAM Advantage

Unlike a Node.js process, Elixir/OTP processes are isolated. One plugin crashing doesn't kill the core. The supervision tree determines what restarts what. `Kyber.Core`'s `:rest_for_one` strategy means a Delta.Store restart cascades to Reducer and Executor (which must re-register with the store), but not to unrelated processes.

```
KyberBeam.Supervisor (:one_for_one)
├── Kyber.Core (:rest_for_one)         ← Core pipeline: fail together
│   ├── Task.Supervisor
│   ├── Kyber.Delta.Store
│   ├── Kyber.State
│   ├── Kyber.Effect.Executor
│   ├── Kyber.Plugin.Manager
│   └── Kyber.Core.PipelineWirer
├── Kyber.Plugin.Discord               ← Isolated: Discord crash ≠ core crash
├── Kyber.Plugin.LLM                   ← Isolated: LLM crash ≠ core crash
└── ...
```

**Principle:** Let it crash. OTP restarts are the recovery mechanism. Don't write defensive code that masks failures — write supervisors that recover from them.

## 2. Error Handling

### Errors Are Deltas

Every error flows through the delta funnel, not a side channel. This means:
- Full provenance (parent_id chain shows what caused the error)
- Observable in the LiveView dashboard
- Queryable from the delta log
- Cost-free aggregation

```elixir
# In Kyber.Effect.Executor on unexpected failure:
delta = %Delta{
  kind: "error.effect",
  parent_id: triggering_delta.id,
  origin: %{type: "system", reason: "effect-executor"},
  payload: %{
    effect_type: effect.type,
    error: Exception.message(e),
    stacktrace: Exception.format_stacktrace(__STACKTRACE__)
  }
}
Kyber.Delta.Store.append(delta)
```

```elixir
# Delta kinds for errors:
"error.effect"           # Effect executor failure
"error.tool"             # Tool execution failure (use tool.error instead)
"error.plugin"           # Plugin init/crash
"plugin.failed"          # Plugin failed to start
"plugin.loaded"          # Plugin started successfully
"error.route"            # HTTP route failure
"error.uncaught"         # Unhandled exception
```

### Plugin Isolation

Plugins fail without taking down the core:

```elixir
defmodule Kyber.Plugin.Manager do
  def start_plugin(plugin_module) do
    case DynamicSupervisor.start_child(__MODULE__, {plugin_module, []}) do
      {:ok, pid} ->
        Kyber.Delta.Store.append(%Delta{
          kind: "plugin.loaded",
          payload: %{name: plugin_module.name()}
        })
        {:ok, pid}

      {:error, reason} ->
        Kyber.Delta.Store.append(%Delta{
          kind: "plugin.failed",
          payload: %{name: plugin_module.name(), error: inspect(reason)}
        })
        # Server continues without this plugin — degraded mode, not crash
        {:error, reason}
    end
  end
end
```

### HTTP Routes

Phoenix/Plug middleware catches errors at the route level:

```elixir
defmodule Kyber.Web.Router do
  use Plug.ErrorHandler

  def handle_errors(conn, %{kind: :error, reason: reason, stack: stack}) do
    delta = %Delta{
      kind: "error.route",
      payload: %{
        method: conn.method,
        path: conn.request_path,
        error: Exception.message(reason)
      }
    }
    Kyber.Delta.Store.append(delta)
    send_resp(conn, 500, Jason.encode!(%{error: "Internal error", delta_id: delta.id}))
  end
end
```

## 3. launchctl Service (macOS)

Auto-start on boot. Auto-restart on crash. Logs to a known location.

The launchctl plist is at `com.liet.kyber-beam.plist`. Key settings:

```xml
<key>KeepAlive</key>
<dict>
  <!-- Restart on crash, but not if we exit cleanly (exit 0) -->
  <key>SuccessfulExit</key>
  <false/>
</dict>

<key>ThrottleInterval</key>
<integer>5</integer>
```

**Service management:**
```bash
# Install
cp com.liet.kyber-beam.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.liet.kyber-beam.plist

# Or use the install script:
./scripts/install.sh

# Control
launchctl start com.liet.kyber-beam
launchctl stop com.liet.kyber-beam

# Check status
launchctl list | grep kyber

# View logs
tail -f ~/.kyber/logs/kyber.stdout.log
tail -f ~/.kyber/logs/kyber.stderr.log
```

## 4. Revert Logic

If a change breaks Kyber beyond restart, we need automatic recovery.

### Layer 1: Health Check

The server writes a heartbeat file periodically. Kyber.Deployment or a separate watchdog checks it.

```elixir
defmodule Kyber.Health do
  @health_file Path.join(System.get_env("HOME", "/tmp"), ".kyber/health.json")
  @interval_ms 30_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    schedule_tick()
    {:ok, %{}}
  end

  def handle_info(:tick, state) do
    health = %{
      ts: System.system_time(:millisecond),
      uptime: :erlang.statistics(:wall_clock) |> elem(0),
      node: Node.self(),
      processes: length(Process.list()),
      version: Application.spec(:kyber_beam, :vsn) |> to_string()
    }
    File.write!(@health_file, Jason.encode!(health))
    schedule_tick()
    {:noreply, state}
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @interval_ms)
end
```

### Layer 2: Known-Good Snapshots + Update Discipline

```
1. Tag current HEAD as known-good (before any change)
2. Apply changes (code, config, deps)
3. Run tests
4. Commit the update to git
5. Restart
6. If healthy → new commit becomes the baseline
7. If crash loop → revert to the known-good tag
```

```bash
# update.sh — run before deploying a change
TAG="known-good-$(date +%s)"
git tag "$TAG" HEAD
echo "$TAG" > ~/.kyber/last-known-good-tag
echo "Tagged $TAG — safe to proceed"
```

### Layer 3: Watchdog Script

A separate launchctl job checks the health file. If stale after restart attempts, reverts to last known good.

```bash
#!/bin/bash
# watchdog.sh — independent launchctl job

KYBER_ROOT="$HOME/kyber-beam"
HEALTH_FILE="$HOME/.kyber/health.json"
MAX_STALE_SEC=120
MAX_RESTART_ATTEMPTS=3
RESTART_COUNT=0

while true; do
  sleep 30

  [ ! -f "$HEALTH_FILE" ] && continue

  LAST_TS=$(jq -r '.ts' "$HEALTH_FILE" 2>/dev/null)
  NOW_MS=$(($(date +%s) * 1000))
  STALE_MS=$(( NOW_MS - LAST_TS ))

  if [ "$STALE_MS" -gt $(( MAX_STALE_SEC * 1000 )) ]; then
    RESTART_COUNT=$((RESTART_COUNT + 1))

    if [ "$RESTART_COUNT" -le "$MAX_RESTART_ATTEMPTS" ]; then
      echo "[watchdog] Restart attempt $RESTART_COUNT/$MAX_RESTART_ATTEMPTS"
      launchctl stop com.liet.kyber-beam
      sleep 2
      launchctl start com.liet.kyber-beam
    else
      echo "[watchdog] Max restarts exceeded. Reverting to known-good."
      TAG=$(cat "$HOME/.kyber/last-known-good-tag" 2>/dev/null)

      if [ -n "$TAG" ]; then
        cd "$KYBER_ROOT"
        git stash
        git checkout "$TAG"
        mix compile --no-deps-check 2>/dev/null

        RESTART_COUNT=0
        launchctl stop com.liet.kyber-beam
        sleep 2
        launchctl start com.liet.kyber-beam
        echo "[watchdog] Reverted to $TAG and restarted."
      else
        echo "[watchdog] No known-good tag. Manual intervention required."
        # Future: emit an alert delta somehow (write to a queue file, etc.)
      fi
    fi
  else
    RESTART_COUNT=0
  fi
done
```

## 5. Hot Reload

Implemented in PR #11. Plugin files are watched via `FileSystem`. On change:

1. Detect changed plugin file
2. Emit `plugin.reload` delta
3. Call `plugin.reload/0` callback if implemented
4. Supervisor restarts the plugin process with new code
5. Emit `plugin.loaded` delta on success

```elixir
# Hot reload doesn't require a full application restart
# BEAM's code loading means module definitions are updated in-place
# Plugin.Manager restarts the GenServer with the new module
```

## 6. OTP-Specific Resilience Patterns

### Back-pressure

When the delta store is overwhelmed (bulk import, replay), tools should apply back-pressure:

```elixir
# Don't let the store mailbox overflow
case Kyber.Delta.Store.append(delta, timeout: 5_000) do
  :ok -> :ok
  {:error, :timeout} ->
    Logger.warning("Delta store back-pressure — dropping non-critical delta")
    # Only drop non-critical deltas; never drop message.received or llm.response
end
```

### Circuit Breaker

For external services (Anthropic, Discord, ElevenLabs), use a circuit breaker pattern to avoid cascading failures:

```elixir
# Simple circuit breaker state in a GenServer
# Open circuit after N consecutive failures
# Half-open after timeout, close on success
```

Consider `:fuse` library for production-grade circuit breaking.

### Delta Store Replay

Because the delta store is append-only JSONL, state can always be reconstructed:

```bash
# Replay all deltas from a specific point
mix kyber.query --from 2026-03-20T00:00:00 --replay
```

## Recovery Flow

```
Code change deployed
  → Tests pass
    → Server restarts (BEAM hot-load or full restart)
      → Healthy? Great, new baseline.
      → Plugin crash?
        → OTP supervisor restarts the plugin (KeepAlive)
          → Plugin emits plugin.failed delta
            → Core continues in degraded mode
      → Core crash?
        → launchctl KeepAlive restarts the OS process
          → State reconstructed from delta log
            → Still crashing?
              → Watchdog detects stale health file
                → Restart attempts 1, 2, 3
                  → Still dead?
                    → git checkout known-good tag
                      → Rebuild + restart
                        → Still dead?
                          → "Manual intervention required"
                          → (Future: notification delta to Discord/phone)
```

## Summary

| Layer | What | Mechanism |
|-------|------|-----------|
| Process crashes | Plugin isolated from core | OTP supervision tree |
| Core restart | State reconstructed from delta log | JSONL append-only log |
| OS process crash | Auto-restart | launchctl KeepAlive |
| Persistent crashes | Revert to known-good commit | Watchdog script |
| External service failures | Circuit breaker + graceful degradation | Plugin-level handling |
| Unrecoverable | Alert human | Future: notification delta |

**Errors are deltas.** They flow through the same funnel as everything else. Full provenance, full traceability. The dashboard shows them. The log preserves them.
