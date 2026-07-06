/**
 * Bootstrap the consolidated `ai-life-coach` autonomous agent group.
 *
 * Replaces the five per-stage groups (po-epic-refiner, po-story-refiner,
 * dev-plan, dev-implement, dev-code-review) with ONE todo-driven agent. Every
 * minute the pre-task gate polls `GET /todos?state=pending`; when a todo is
 * waiting it classifies it into one mode + one model and wakes the agent, which
 * selects the matching skill (srs / epic / story / plan / implement / review),
 * does the one action, marks the todo done, and stops. Empty todo list -> no
 * LLM spend. All output goes to GitLab — no chat channel.
 *
 * Creates the agent group + filesystem, a synthetic `cli:life-coach` messaging
 * group + wiring (session host only), an active session, and injects a recurring
 * task (every minute) whose content carries { prompt, script:<gate> }.
 *
 * Sets the RESTING model to claude-sonnet-4-6 in container_configs. The gate
 * overrides the model per wake (Opus only for a story dev-plan) via the
 * scriptOutput.model path threaded through the poll-loop.
 *
 * Safe to re-run: reuses group/mg/wiring/session if present, refuses to insert
 * a duplicate live task.
 *
 * After this runs, provision the OneCLI agent for GitLab auth:
 *   onecli agents create --identifier <group-id> --name ai-life-coach
 *   onecli agents set-secret-mode --id <onecli-agent-id> --mode all
 *
 * Usage: pnpm exec tsx scripts/init-life-coach.ts
 */
import fs from 'fs';
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { createAgentGroup, getAgentGroupByFolder } from '../src/db/agent-groups.js';
import { initDb } from '../src/db/connection.js';
import {
  createMessagingGroup,
  createMessagingGroupAgent,
  getMessagingGroupAgentByPair,
  getMessagingGroupByPlatform,
} from '../src/db/messaging-groups.js';
import { runMigrations } from '../src/db/migrations/index.js';
import { initGroupFilesystem } from '../src/group-init.js';
import { insertTask } from '../src/modules/scheduling/db.js';
import {
  openInboundDb,
  resolveSession,
  writeSessionRouting,
} from '../src/session-manager.js';
import type { AgentGroup, MessagingGroup } from '../src/types.js';

const FOLDER = 'ai-life-coach';
const CLI_CHANNEL = 'cli';
const CLI_PLATFORM_ID = 'life-coach';
const SCRATCH = path.resolve('scratch-life-coach');
const MODEL = 'claude-sonnet-4-6'; // resting model; gate overrides per wake

const TASK_PROMPT = [
  'Scheduled ai-life-coach scan.',
  '',
  'The pre-task gate polled GitLab todos and selected exactly ONE pending todo, passed as `Script output` above: { mode, model, todo: { id, action, target_type, target_iid, target_slug, target_url, project_id, body, author, labels } }.',
  '',
  'Follow your workflow (CLAUDE.local.md): select the skill for this todo — the gate\'s `mode` is only a hint, you are the authority — load it, perform that ONE action, then mark the todo done (`POST https://gitlab.com/api/v4/todos/<todo.id>/mark_as_done`) and stop. Keep every label/state transition, the `human-needed` label, and the `@protoswype-group/life-coach` mention exactly as the skill requires. For `implement`/`review`, real git works through the gateway (clone/checkout `feature/<iid>`/build/test/push); drive the implement↔review loop via a self-mention hand-off line plus a self-created MR todo (`POST .../merge_requests/<iid>/todo`), and NEVER exceed 3 consecutive self-hops — the 4th must instead label the story `human-needed`. Prefix every comment with `<!-- ai-life-coach:auto -->`.',
].join('\n');

function generateId(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

async function main(): Promise<void> {
  const instructions = fs.readFileSync(path.join(SCRATCH, 'CLAUDE.md'), 'utf8');
  const gateScript = fs.readFileSync(path.join(SCRATCH, 'gate.sh'), 'utf8');

  const db = initDb(path.join(DATA_DIR, 'v2.db'));
  runMigrations(db);
  const now = new Date().toISOString();

  // 1. Agent group + filesystem.
  let ag: AgentGroup | undefined = getAgentGroupByFolder(FOLDER);
  if (!ag) {
    createAgentGroup({ id: generateId('ag'), name: FOLDER, folder: FOLDER, agent_provider: null, created_at: now });
    ag = getAgentGroupByFolder(FOLDER)!;
    console.log(`Created agent group: ${ag.id} (${FOLDER})`);
  } else {
    console.log(`Reusing agent group: ${ag.id} (${FOLDER})`);
  }
  initGroupFilesystem(ag, { instructions });
  fs.writeFileSync(path.resolve('groups', FOLDER, 'CLAUDE.local.md'), instructions + '\n');
  fs.writeFileSync(path.resolve('groups', FOLDER, 'gate.sh'), gateScript);

  // 2. Set resting model in container_configs.
  const existing = db
    .prepare('SELECT agent_group_id FROM container_configs WHERE agent_group_id = ?')
    .get(ag.id) as { agent_group_id: string } | undefined;
  if (existing) {
    db.prepare('UPDATE container_configs SET model = ?, updated_at = ? WHERE agent_group_id = ?')
      .run(MODEL, now, ag.id);
    console.log(`Set model ${MODEL} on existing container_config`);
  } else {
    db.prepare(
      'INSERT INTO container_configs (agent_group_id, model, skills, mcp_servers, packages_apt, packages_npm, additional_mounts, updated_at, cli_scope) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
    ).run(ag.id, MODEL, '"all"', '{}', '[]', '[]', '[]', now, 'group');
    console.log(`Created container_config with model ${MODEL}`);
  }

  // 3. Synthetic CLI messaging group + wiring (session host only).
  let mg: MessagingGroup | undefined = getMessagingGroupByPlatform(CLI_CHANNEL, CLI_PLATFORM_ID);
  if (!mg) {
    mg = {
      id: generateId('mg'),
      channel_type: CLI_CHANNEL,
      platform_id: CLI_PLATFORM_ID,
      name: 'ai-life-coach (scheduler)',
      is_group: 0,
      unknown_sender_policy: 'public',
      created_at: now,
    };
    createMessagingGroup(mg);
    console.log(`Created messaging group: ${mg.id}`);
  }
  if (!getMessagingGroupAgentByPair(mg.id, ag.id)) {
    createMessagingGroupAgent({
      id: generateId('mga'),
      messaging_group_id: mg.id,
      agent_group_id: ag.id,
      engage_mode: 'pattern',
      engage_pattern: '.',
      sender_scope: 'all',
      ignored_message_policy: 'drop',
      session_mode: 'shared',
      priority: 0,
      created_at: now,
    });
    console.log(`Wired ${mg.id} -> ${ag.id}`);
  }

  // 4. Session (creates inbound.db + outbound.db).
  const { session, created } = resolveSession(ag.id, mg.id, null, 'shared');
  console.log(`Session: ${session.id} (${created ? 'created' : 'reused'})`);
  writeSessionRouting(ag.id, session.id);

  // 5. Recurring gated task. First fire +3min so OneCLI auth can be set up first.
  const inDb = openInboundDb(ag.id, session.id);
  try {
    const live = inDb
      .prepare("SELECT COUNT(*) c FROM messages_in WHERE kind='task' AND status IN ('pending','paused')")
      .get() as { c: number };
    if (live.c > 0) {
      console.log(`Live task already present (${live.c}); not inserting a duplicate.`);
    } else {
      const processAfter = new Date(Date.now() + 3 * 60_000).toISOString();
      insertTask(inDb, {
        id: generateId('task'),
        processAfter,
        recurrence: '* * * * *',
        platformId: CLI_PLATFORM_ID,
        channelType: CLI_CHANNEL,
        threadId: null,
        content: JSON.stringify({ prompt: TASK_PROMPT, script: gateScript }),
      });
      console.log(`Inserted recurring task (first fire ${processAfter}, cron * * * * *)`);
    }
  } finally {
    inDb.close();
  }

  console.log('');
  console.log(`Agent group id: ${ag.id}`);
  console.log('Next: provision OneCLI GitLab auth for this agent:');
  console.log(`  onecli agents create --identifier ${ag.id} --name ai-life-coach`);
  console.log(`  onecli agents set-secret-mode --id <printed-agent-id> --mode all`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
