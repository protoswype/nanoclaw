/**
 * Bootstrap the `po-epic-refiner` autonomous agent group.
 *
 * Creates the agent group + filesystem, a synthetic `cli:po-epic-refiner`
 * messaging group + wiring (only to host a session — the agent has no chat
 * output; everything goes to GitLab), an active session, and injects a
 * recurring task (every 15 min) whose pre-task gate polls GitLab and only
 * wakes the LLM when one SRS is actionable.
 *
 * Reads the workflow (CLAUDE.local.md) and the gate script from
 * scratch-epic-refiner/. Safe to re-run: reuses the group/mg/wiring/session
 * if present, and refuses to insert a duplicate live task.
 *
 * After this runs, provision the OneCLI agent for GitLab auth:
 *   onecli agents create --identifier <group-id> --name po-epic-refiner
 *   onecli agents set-secret-mode --id <onecli-agent-id> --mode all
 *
 * Usage: pnpm exec tsx scripts/init-epic-refiner.ts
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

const FOLDER = 'ai-life-coach_po-epic-refiner';
const CLI_CHANNEL = 'cli';
const CLI_PLATFORM_ID = 'po-epic-refiner';
const SCRATCH = path.resolve('scratch-epic-refiner');

const TASK_PROMPT = [
  'Scheduled po-epic-refiner scan.',
  '',
  'The pre-task gate has already selected exactly ONE actionable item and passed it as `Script output` above: an object { srs, slug, meta, action, epicIid? }.',
  '',
  'Follow your workflow (CLAUDE.local.md) and perform ONLY the single `action` for that one SRS/epic, then stop. Make every GitLab change via the REST/GraphQL API with curl (auth is injected by the gateway). Prefix every comment you post with the marker line `<!-- po-epic-refiner:auto -->` and @mention @protoswype-group/life-coach on human-facing comments. Never create epics without a ✅ on the proposal; never add a ✅ yourself.',
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

  // 1. Agent group + filesystem (workflow lands in CLAUDE.local.md).
  let ag: AgentGroup | undefined = getAgentGroupByFolder(FOLDER);
  if (!ag) {
    createAgentGroup({ id: generateId('ag'), name: FOLDER, folder: FOLDER, agent_provider: null, created_at: now });
    ag = getAgentGroupByFolder(FOLDER)!;
    console.log(`Created agent group: ${ag.id} (${FOLDER})`);
  } else {
    console.log(`Reusing agent group: ${ag.id} (${FOLDER})`);
  }
  initGroupFilesystem(ag, { instructions });
  // Refresh CLAUDE.local.md even on re-run (initGroupFilesystem only seeds it once).
  fs.writeFileSync(path.resolve('groups', FOLDER, 'CLAUDE.local.md'), instructions + '\n');
  fs.writeFileSync(path.resolve('groups', FOLDER, 'gate.sh'), gateScript);

  // 2. Synthetic CLI messaging group + wiring (session host only).
  let mg: MessagingGroup | undefined = getMessagingGroupByPlatform(CLI_CHANNEL, CLI_PLATFORM_ID);
  if (!mg) {
    mg = {
      id: generateId('mg'),
      channel_type: CLI_CHANNEL,
      platform_id: CLI_PLATFORM_ID,
      name: 'po-epic-refiner (scheduler)',
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

  // 3. Session (creates inbound.db + outbound.db).
  const { session, created } = resolveSession(ag.id, mg.id, null, 'shared');
  console.log(`Session: ${session.id} (${created ? 'created' : 'reused'})`);
  writeSessionRouting(ag.id, session.id);

  // 4. Recurring gated task. First fire +3min so OneCLI auth can be set up first.
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
        recurrence: '*/15 * * * *',
        platformId: CLI_PLATFORM_ID,
        channelType: CLI_CHANNEL,
        threadId: null,
        content: JSON.stringify({ prompt: TASK_PROMPT, script: gateScript }),
      });
      console.log(`Inserted recurring task (first fire ${processAfter}, cron */15 * * * *)`);
    }
  } finally {
    inDb.close();
  }

  console.log('');
  console.log('Next: provision OneCLI GitLab auth for this agent:');
  console.log(`  onecli agents create --identifier ${ag.id} --name po-epic-refiner`);
  console.log(`  onecli agents set-secret-mode --id <printed-agent-id> --mode all`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
