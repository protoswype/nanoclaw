import { execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import type { MessageInRow } from '../db/messages-in.js';
import { touchHeartbeat } from '../db/connection.js';

const SCRIPT_TIMEOUT_MS = 30_000;
// Cap for per-task overrides (content.scriptTimeoutSeconds). Must stay well
// below the host's 30-min stale-heartbeat kill ceiling (src/host-sweep.ts) —
// the heartbeat is touched on an interval while the script runs, but a
// runaway script must still lose to the timeout before the host loses
// patience with the container.
const SCRIPT_TIMEOUT_MAX_MS = 20 * 60_000;
const SCRIPT_MAX_BUFFER = 1024 * 1024;
const HEARTBEAT_INTERVAL_MS = 30_000;

export interface ScriptResult {
  wakeAgent: boolean;
  data?: unknown;
}

function log(msg: string): void {
  console.error(`[task-script] ${msg}`);
}

export async function runScript(script: string, taskId: string, timeoutMs: number = SCRIPT_TIMEOUT_MS): Promise<ScriptResult | null> {
  const scriptPath = path.join('/tmp', `task-script-${taskId}.sh`);
  fs.writeFileSync(scriptPath, script, { mode: 0o755 });

  // Long-running scripts (per-task timeout override) must keep the heartbeat
  // fresh or the host sweep will kill the container mid-scrape.
  const heartbeat = setInterval(touchHeartbeat, HEARTBEAT_INTERVAL_MS);

  return new Promise((resolve) => {
    execFile(
      'bash',
      [scriptPath],
      { timeout: timeoutMs, maxBuffer: SCRIPT_MAX_BUFFER, env: process.env },
      (error, stdout, stderr) => {
        clearInterval(heartbeat);
        try {
          fs.unlinkSync(scriptPath);
        } catch {
          /* best-effort cleanup */
        }

        if (stderr) {
          log(`[${taskId}] stderr: ${stderr.slice(0, 500)}`);
        }

        if (error) {
          log(`[${taskId}] error: ${error.message}`);
          return resolve(null);
        }

        const lines = stdout.trim().split('\n');
        const lastLine = lines[lines.length - 1];
        if (!lastLine) {
          log(`[${taskId}] no output`);
          return resolve(null);
        }

        try {
          const result = JSON.parse(lastLine);
          if (typeof result.wakeAgent !== 'boolean') {
            log(`[${taskId}] output missing wakeAgent boolean: ${lastLine.slice(0, 200)}`);
            return resolve(null);
          }
          resolve(result as ScriptResult);
        } catch {
          log(`[${taskId}] output is not valid JSON: ${lastLine.slice(0, 200)}`);
          resolve(null);
        }
      },
    );
  });
}

export interface TaskScriptOutcome {
  keep: MessageInRow[];
  skipped: string[];
}

/**
 * Run pre-task scripts for any task messages that carry one, serially.
 * - Errors / missing output / wakeAgent=false → task id added to `skipped`.
 * - wakeAgent=true → content JSON is mutated to carry `scriptOutput`, so the
 *   formatter renders it into the prompt.
 * Non-task messages and tasks without scripts pass through unchanged.
 */
export async function applyPreTaskScripts(messages: MessageInRow[]): Promise<TaskScriptOutcome> {
  const keep: MessageInRow[] = [];
  const skipped: string[] = [];

  for (const msg of messages) {
    if (msg.kind !== 'task') {
      keep.push(msg);
      continue;
    }

    let content: Record<string, unknown>;
    try {
      content = JSON.parse(msg.content);
    } catch {
      keep.push(msg);
      continue;
    }

    const script = typeof content.script === 'string' ? (content.script as string) : null;
    if (!script) {
      keep.push(msg);
      continue;
    }

    // Optional per-task timeout override (seconds), capped. Tasks whose
    // script does real work (scrape + push cycles) need more than the 30s
    // default; the cap keeps a runaway script below the host kill ceiling.
    const timeoutMs =
      typeof content.scriptTimeoutSeconds === 'number' && content.scriptTimeoutSeconds > 0
        ? Math.min(content.scriptTimeoutSeconds * 1000, SCRIPT_TIMEOUT_MAX_MS)
        : undefined;

    log(`running script for task ${msg.id}${timeoutMs ? ` (timeout ${timeoutMs / 1000}s)` : ''}`);
    touchHeartbeat();
    const result = await runScript(script, msg.id, timeoutMs);
    touchHeartbeat();

    if (!result || !result.wakeAgent) {
      const reason = result ? 'wakeAgent=false' : 'script error/no output';
      log(`task ${msg.id} skipped: ${reason}`);
      skipped.push(msg.id);
      continue;
    }

    log(`task ${msg.id} wakeAgent=true, enriching prompt`);
    content.scriptOutput = result.data ?? null;
    keep.push({ ...msg, content: JSON.stringify(content) });
  }

  return { keep, skipped };
}
