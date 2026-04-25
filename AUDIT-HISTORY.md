# Kyber-BEAM Audit History

*This document preserves the critical engineering and security findings from the legacy audit files. All new code must be reviewed against these constraints.*

## Architecture Audit Findings
**C1. Application-Level OTP Compliance:** The top-level supervisor strategy (`:rest_for_one` in `Kyber.Core`) is sound, but does not protect against Core restarts breaking plugin state in `PluginManager`. Hot-reloading must explicitly handle state handoff.
**C2. Blocking I/O in GenServers:** The `Delta.Store` and `Kyber.Session` modules contain paths that perform blocking disk I/O inside `handle_call` or `handle_cast`. Under load, this will exhaust the mailbox. **Mandate:** Defer replies via `spawn_monitor` or `Task` for all disk operations.
**C3. Test Fragility:** Widespread use of `Process.sleep/1` for asynchronous coordination in integration tests. **Mandate:** Replace with `assert_receive/3` or `Process.send_after/3` polling.

**H1. O(n) History Appends:** `Kyber.Session` history appends were O(n). Fixed, but regressions must be prevented.
**H2. Knowledge Reload Race:** `Kyber.Knowledge` polling the Obsidian vault must track `reload_task_ref` to skip overlapping pulls.

## Security Audit Findings
**S1. Exec Allowlist Bypass:** The original `String.split(~r/[\s|;&]/)` logic only checked the first token, allowing shell injection (`git; rm -rf /`). Fixed via `contains_shell_injection?/1` guard. All new tools utilizing `System.cmd` must pass this strict regex filtering before execution.
**S2. Unauthenticated Endpoints:** `POST /api/deltas` previously bypassed `BearerAuth`. All web routes except `/health` must remain behind strict API key validation.
**S3. Ephemeral Leakage:** The web router must route deltas through `Kyber.Core.emit/2` rather than `Store.append/2` directly, to ensure ephemeral deltas (like `cron.fired`) are stripped before disk persistence.
