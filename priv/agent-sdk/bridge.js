#!/usr/bin/env node
/**
 * bridge.js — JSON-lines bridge between kyber-beam (Elixir Port) and Claude Agent SDK.
 *
 * Protocol:
 *   stdin  → JSON lines: prompt requests and tool results
 *   stdout → JSON lines: responses and tool call requests
 *   stderr → diagnostic logging (not parsed by Elixir)
 *
 * Request (prompt):
 *   {"id":"xxx","type":"prompt","prompt":"...","system":"...","tools":[...]}
 *
 * Request (tool result):
 *   {"id":"xxx","type":"tool_result","tool_use_id":"...","content":"..."}
 *
 * Response:
 *   {"id":"xxx","type":"response","content":"...","tool_calls":[...],"stop_reason":"...","usage":{...}}
 *
 * Error:
 *   {"id":"xxx","type":"error","error":"..."}
 *
 * Auth: reads OAuth token from ~/.claude/ or ANTHROPIC_API_KEY env var.
 */

const { createInterface } = require("readline");
const fs = require("fs");
const path = require("path");

// ── Logging (stderr only — stdout is for protocol) ────────────────────────
function log(...args) {
  process.stderr.write(`[bridge] ${args.join(" ")}\n`);
}

// ── Send JSON line to stdout ──────────────────────────────────────────────
function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

// ── Auth token discovery ──────────────────────────────────────────────────
function findAuthToken() {
  // 1. Environment variable
  if (process.env.ANTHROPIC_API_KEY) {
    log("auth: using ANTHROPIC_API_KEY env var");
    return { token: process.env.ANTHROPIC_API_KEY, type: "api_key" };
  }

  // 2. Claude CLI credentials (~/.claude/)
  const claudeDir = path.join(process.env.HOME || "", ".claude");
  const credPaths = [
    path.join(claudeDir, "credentials.json"),
    path.join(claudeDir, "auth.json"),
  ];

  for (const credPath of credPaths) {
    try {
      const data = JSON.parse(fs.readFileSync(credPath, "utf8"));
      const token =
        data.oauthToken ||
        data.accessToken ||
        data.token ||
        (data.claudeAiOauth && data.claudeAiOauth.accessToken);
      if (token) {
        log(`auth: found token in ${credPath}`);
        const type = token.startsWith("sk-ant-oat") ? "oauth" : "api_key";
        return { token, type };
      }
    } catch {
      // file doesn't exist or isn't valid JSON
    }
  }

  // 3. OpenClaw auth profiles (legacy)
  const openclawPath = path.join(
    process.env.HOME || "",
    ".openclaw/agents/main/agent/auth-profiles.json"
  );
  try {
    const data = JSON.parse(fs.readFileSync(openclawPath, "utf8"));
    const token = extractTokenRecursive(data);
    if (token) {
      log(`auth: found token in ${openclawPath}`);
      const type = token.startsWith("sk-ant-oat") ? "oauth" : "api_key";
      return { token, type };
    }
  } catch {
    // not found
  }

  return null;
}

function extractTokenRecursive(obj) {
  if (!obj || typeof obj !== "object") return null;
  for (const [, value] of Object.entries(obj)) {
    if (typeof value === "string" && value.startsWith("sk-ant-") && value.length > 20) {
      return value;
    }
    if (typeof value === "object") {
      const found = extractTokenRecursive(value);
      if (found) return found;
    }
  }
  return null;
}

// ── Agent SDK interaction ─────────────────────────────────────────────────

let ClaudeAgent = null;
let agentSdkAvailable = false;

try {
  // Attempt to load the Agent SDK
  const sdk = require("@anthropic-ai/claude-agent-sdk");
  ClaudeAgent = sdk.ClaudeAgent || sdk.Agent || sdk.default;
  agentSdkAvailable = !!ClaudeAgent;
  log(`agent-sdk: loaded (constructor: ${ClaudeAgent?.name || "unknown"})`);
} catch (err) {
  log(`agent-sdk: not available — ${err.message}`);
  log("agent-sdk: bridge will report unavailable to Elixir side");
}

// Active conversations keyed by request ID
const conversations = new Map();

async function handlePrompt(msg) {
  const { id, prompt, system, tools, model, messages } = msg;

  if (!agentSdkAvailable) {
    send({ id, type: "error", error: "agent_sdk_unavailable" });
    return;
  }

  const auth = findAuthToken();
  if (!auth) {
    send({ id, type: "error", error: "no_auth_token" });
    return;
  }

  try {
    // Build the agent configuration
    const agentConfig = {
      model: model || "claude-sonnet-4-20250514",
      authToken: auth.token,
    };

    if (system) agentConfig.systemPrompt = system;
    if (tools && tools.length > 0) agentConfig.tools = tools;

    const agent = new ClaudeAgent(agentConfig);
    conversations.set(id, agent);

    // Run the prompt through the agent
    const input = messages || [{ role: "user", content: prompt }];
    const response = await agent.run(input);

    // Extract tool calls if any
    const toolCalls = [];
    const textParts = [];

    if (Array.isArray(response.content)) {
      for (const block of response.content) {
        if (block.type === "tool_use") {
          toolCalls.push({
            id: block.id,
            name: block.name,
            input: block.input,
          });
        } else if (block.type === "text") {
          textParts.push(block.text);
        }
      }
    } else if (typeof response.content === "string") {
      textParts.push(response.content);
    }

    send({
      id,
      type: "response",
      content: textParts.join("\n"),
      content_blocks: response.content,
      tool_calls: toolCalls,
      stop_reason: response.stop_reason || "end_turn",
      usage: response.usage || {},
      model: response.model,
    });
  } catch (err) {
    log(`error handling prompt ${id}: ${err.message}`);
    send({ id, type: "error", error: err.message });
  }
}

async function handleToolResult(msg) {
  const { id, tool_use_id, content } = msg;

  const agent = conversations.get(id);
  if (!agent) {
    send({ id, type: "error", error: "no_active_conversation" });
    return;
  }

  try {
    const response = await agent.submitToolResult(tool_use_id, content);

    const toolCalls = [];
    const textParts = [];

    if (Array.isArray(response.content)) {
      for (const block of response.content) {
        if (block.type === "tool_use") {
          toolCalls.push({
            id: block.id,
            name: block.name,
            input: block.input,
          });
        } else if (block.type === "text") {
          textParts.push(block.text);
        }
      }
    }

    send({
      id,
      type: "response",
      content: textParts.join("\n"),
      content_blocks: response.content,
      tool_calls: toolCalls,
      stop_reason: response.stop_reason || "end_turn",
      usage: response.usage || {},
      model: response.model,
    });
  } catch (err) {
    log(`error handling tool result ${id}: ${err.message}`);
    send({ id, type: "error", error: err.message });
  }
}

// ── Heartbeat: respond to pings so Elixir knows we're alive ──────────────
function handlePing(msg) {
  send({
    id: msg.id,
    type: "pong",
    agent_sdk_available: agentSdkAvailable,
  });
}

// ── Main loop: read JSON lines from stdin ─────────────────────────────────
const rl = createInterface({ input: process.stdin, terminal: false });

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;

  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch (err) {
    log(`invalid JSON: ${err.message}`);
    return;
  }

  switch (msg.type) {
    case "prompt":
      handlePrompt(msg).catch((err) => {
        log(`unhandled prompt error: ${err.message}`);
        send({ id: msg.id, type: "error", error: err.message });
      });
      break;

    case "tool_result":
      handleToolResult(msg).catch((err) => {
        log(`unhandled tool_result error: ${err.message}`);
        send({ id: msg.id, type: "error", error: err.message });
      });
      break;

    case "ping":
      handlePing(msg);
      break;

    default:
      log(`unknown message type: ${msg.type}`);
      send({ id: msg.id, type: "error", error: `unknown type: ${msg.type}` });
  }
});

rl.on("close", () => {
  log("stdin closed, shutting down");
  process.exit(0);
});

// Signal readiness
send({ type: "ready", agent_sdk_available: agentSdkAvailable });
log("bridge started, waiting for requests...");
