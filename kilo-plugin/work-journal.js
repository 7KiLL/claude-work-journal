import { spawn } from "node:child_process";
import { appendFile, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir, tmpdir } from "node:os";
import { fileURLToPath } from "node:url";

const PLUGIN_FILE = realpathSync(fileURLToPath(import.meta.url));
const PLUGIN_DIR = dirname(PLUGIN_FILE);
const PLUGIN_ROOT = resolve(PLUGIN_DIR, "..");
const DEFAULT_CAPTURE_DELAY_MS = 30_000;
const DEFAULT_MAX_MESSAGES = 200;

function numberOption(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

function isOpenCodeHost() {
  return process.argv.some((arg) => /(^|[/\\])opencode(?:\.exe)?$/i.test(arg));
}

function envWithRoot() {
  return {
    ...process.env,
    PLUGIN_ROOT: process.env.PLUGIN_ROOT || PLUGIN_ROOT,
  };
}

function journalDir() {
  return process.env.WORK_JOURNAL_DIR || join(homedir(), ".claude", "work-journal");
}

async function logError(message) {
  try {
    const dir = journalDir();
    await mkdir(dir, { recursive: true });
    await appendFile(join(dir, ".errors.log"), `[${new Date().toISOString()}] work-journal-adapter: ${message}\n`, "utf8");
  } catch {
    // Hooks must never block the harness because logging failed.
  }
}

function runCommand(command, args, { input, cwd, timeoutMs = 10_000 } = {}) {
  return new Promise((resolveResult) => {
    const child = spawn(command, args, {
      cwd,
      env: envWithRoot(),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGTERM"), timeoutMs);
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", (error) => {
      clearTimeout(timer);
      resolveResult({ code: 1, stdout, stderr: `${stderr}${error.message}` });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolveResult({ code: code ?? 0, stdout, stderr });
    });
    if (input) child.stdin.end(input); else child.stdin.end();
  });
}

async function runRecall(cwd) {
  const result = await runCommand("bash", [join(PLUGIN_ROOT, "hooks", "recall.sh")], {
    cwd,
    input: `${JSON.stringify({ cwd })}\n`,
  });
  if (result.code !== 0 || !result.stdout.trim()) return "";
  try {
    const parsed = JSON.parse(result.stdout);
    return parsed?.hookSpecificOutput?.additionalContext || "";
  } catch {
    return "";
  }
}

function extractData(response) {
  if (!response) return undefined;
  if (response.data !== undefined) return response.data;
  return response;
}

function messageTime(message) {
  return message?.time?.completed || message?.time?.updated || message?.time?.created || 0;
}

function compactPart(part) {
  if (!part || typeof part !== "object") return part;
  if (part.type === "tool") {
    return {
      type: part.type,
      tool: part.tool,
      state: part.state,
      metadata: part.metadata,
    };
  }
  if (part.type === "file") {
    return {
      type: part.type,
      filename: part.filename,
      mime: part.mime,
      source: part.source,
    };
  }
  return part;
}

function transcriptLine(entry) {
  return JSON.stringify({
    message: entry.info,
    parts: (entry.parts || []).map(compactPart),
  });
}

function latestMessageID(entries) {
  let latest;
  for (const entry of entries) {
    if (!entry?.info?.id) continue;
    if (!latest || messageTime(entry.info) >= messageTime(latest.info)) latest = entry;
  }
  return latest?.info?.id || "session";
}

async function fetchMessages(client, sessionID, cwd, limit) {
  const attempts = [
    () => client.session.messages({ sessionID, directory: cwd, limit }),
    () => client.session.messages({ path: { id: sessionID }, query: { limit } }),
    () => client.session.messages({ path: { id: sessionID } }),
  ];
  let lastError;
  for (const attempt of attempts) {
    try {
      const data = extractData(await attempt());
      if (Array.isArray(data)) return data.slice(-limit);
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || new Error("session messages unavailable");
}

async function writeTranscript(entries) {
  const dir = await mkdtemp(join(tmpdir(), "work-journal-kilo-"));
  const file = join(dir, "transcript.jsonl");
  await writeFile(file, `${entries.map(transcriptLine).join("\n")}\n`, "utf8");
  return file;
}

async function spawnCapture(transcript, cwd, sessionID, captureKey, host) {
  const capture = join(PLUGIN_ROOT, "hooks", "capture.sh");
  const script = "mem=\"${WORK_JOURNAL_DIR:-$HOME/.claude/work-journal}\"; mkdir -p \"$mem\"; bash \"$1\" --worker \"$2\" \"$3\" \"$4\" \"$5\" >> \"$mem/.errors.log\" 2>&1";
  const child = spawn("bash", ["-lc", script, "work-journal-capture", capture, transcript, cwd, sessionID, captureKey], {
    detached: true,
    env: {
      ...envWithRoot(),
      WORK_JOURNAL_DELETE_TRANSCRIPT: "1",
      WORK_JOURNAL_HOST: host,
    },
    stdio: "ignore",
  });
  child.on("error", () => undefined);
  child.unref();
}

function eventSessionID(event) {
  return event?.properties?.sessionID
    || event?.properties?.sessionId
    || event?.properties?.id
    || event?.properties?.session?.id
    || event?.sessionID
    || event?.sessionId
    || event?.id;
}

async function sendRecallContext(client, sessionID, cwd, context) {
  const body = {
    noReply: true,
    parts: [{ type: "text", text: context }],
  };
  const attempts = [
    () => client.session.prompt({ path: { id: sessionID }, body }),
    () => client.session.prompt({ sessionID, directory: cwd, ...body }),
  ];
  for (const attempt of attempts) {
    try {
      await attempt();
      return true;
    } catch {
      // Try the next SDK shape. OpenCode and Kilo expose similar but not
      // identical generated clients.
    }
  }
  return false;
}

async function WorkJournal({ client, directory, worktree }, options = {}) {
  if (process.env.WORK_JOURNAL_LOCK) return {};

  const cwd = directory || worktree || process.cwd();
  const captureDelayMs = numberOption(
    options.captureDelayMs ?? process.env.WORK_JOURNAL_KILO_CAPTURE_DELAY_MS,
    DEFAULT_CAPTURE_DELAY_MS,
  );
  const maxMessages = numberOption(options.maxMessages, DEFAULT_MAX_MESSAGES);
  const enableRecall = options.recall !== false;
  const enableCapture = options.capture !== false;
  const host = isOpenCodeHost() ? "opencode" : "kilo";
  const enableSessionPromptRecall = enableRecall && (options.sessionPromptRecall ?? isOpenCodeHost());
  const pending = new Map();
  const captured = new Set();
  const recalled = new Set();

  async function captureSession(sessionID) {
    if (!enableCapture || !sessionID) return;
    let entries;
    try {
      entries = await fetchMessages(client, sessionID, cwd, maxMessages);
    } catch (error) {
      await logError(`could not fetch messages for ${sessionID}: ${error?.message || error}`);
      return;
    }
    if (!entries.length) return;
    const lastID = latestMessageID(entries);
    const captureKey = `${sessionID}:${lastID}`;
    if (captured.has(captureKey)) return;
    captured.add(captureKey);
    try {
      const transcript = await writeTranscript(entries);
      await spawnCapture(transcript, cwd, sessionID, captureKey, host);
    } catch (error) {
      await logError(`could not start capture for ${captureKey}: ${error?.message || error}`);
    }
  }

  function scheduleCapture(sessionID) {
    if (!enableCapture || !sessionID) return;
    const current = pending.get(sessionID);
    if (current) clearTimeout(current);
    pending.set(sessionID, setTimeout(() => {
      pending.delete(sessionID);
      captureSession(sessionID).catch(() => undefined);
    }, captureDelayMs));
  }

  async function flushCaptures() {
    const sessionIDs = [...pending.keys()];
    for (const timer of pending.values()) clearTimeout(timer);
    pending.clear();
    await Promise.all(sessionIDs.map((sessionID) => captureSession(sessionID)));
  }

  async function injectSessionRecall(sessionID) {
    if (!enableSessionPromptRecall || !sessionID || recalled.has(sessionID)) return;
    recalled.add(sessionID);
    const context = await runRecall(cwd);
    if (!context) return;
    const ok = await sendRecallContext(client, sessionID, cwd, context);
    if (!ok) await logError(`could not inject recall context for ${sessionID}`);
  }

  return {
    async dispose() {
      await flushCaptures();
    },
    async event({ event }) {
      const sessionID = eventSessionID(event);
      if (enableSessionPromptRecall && (event.type === "session.created" || event.type === "session.updated" || event.type === "session.status")) {
        injectSessionRecall(sessionID).catch(() => undefined);
      }
      if (!enableCapture) return;
      if (event.type === "session.idle" || event.type === "session.turn.close") {
        scheduleCapture(sessionID);
      }
    },
    async "experimental.chat.system.transform"(input, output) {
      if (!enableRecall) return;
      const context = await runRecall(cwd);
      if (!Array.isArray(output.system)) output.system = [];
      if (context) output.system.push(context);
    },
  };
}

export { WorkJournal };
export default WorkJournal;
