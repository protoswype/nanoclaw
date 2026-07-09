/**
 * Bootstrap the `car-finder` agent group.
 *
 * Hourly scheduled task whose pre-task gate (scratch-car-finder/gate.sh)
 * runs the WHOLE scrape → distance → commit → push cycle without the LLM.
 * The agent only wakes when last_run.json reports new offers (to send a
 * Telegram notification) or when the gate fails (to report the error).
 *
 * Creates: agent group + filesystem, synthetic `cli:car-finder` messaging
 * group + wiring (session host only), an active session, container config
 * with python3, and the recurring gated task. Safe to re-run: reuses
 * existing rows and refuses to insert a duplicate live task.
 *
 * After this runs:
 *   1. onecli agents create --identifier <group-id> --name car-finder
 *      onecli agents set-secret-mode --id <onecli-agent-id> --mode all
 *      (auto-created agents start `selective` = NO secrets; git push would 401)
 *   2. Pair the target Telegram chat and add a destination named `telegram`
 *      for this group (see AskUserQuestion flow / docs).
 *
 * Usage: pnpm exec tsx scripts/init-car-finder.ts
 */
import fs from 'fs';
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { createAgentGroup, getAgentGroupByFolder } from '../src/db/agent-groups.js';
import { initDb } from '../src/db/connection.js';
import { ensureContainerConfig, updateContainerConfigJson } from '../src/db/container-configs.js';
import {
  createMessagingGroup,
  createMessagingGroupAgent,
  getMessagingGroupAgentByPair,
  getMessagingGroupByPlatform,
} from '../src/db/messaging-groups.js';
import { runMigrations } from '../src/db/migrations/index.js';
import { initGroupFilesystem } from '../src/group-init.js';
import { insertTask } from '../src/modules/scheduling/db.js';
import { openInboundDb, resolveSession, writeSessionRouting } from '../src/session-manager.js';
import type { AgentGroup, MessagingGroup } from '../src/types.js';

const FOLDER = 'car-finder';
const CLI_CHANNEL = 'cli';
const CLI_PLATFORM_ID = 'car-finder';
const SCRATCH = path.resolve('scratch-car-finder');
const RECURRENCE = '7 * * * *'; // hourly, off the :00 spike

const TASK_PROMPT = [
  'Scheduled car-finder run. The pre-task gate already did the whole cycle (scrape, distances, commit, push — Pages redeploys); you were woken because the `Script output` above needs a human notification.',
  '',
  'If it contains an `offers` array: send ONE concise Telegram message to the destination named `telegram` — one line per offer (title, price, kilometerstand, first-registration year, city, distance from Munich + travel time, kleinanzeigen link), final line the `pagesUrl`.',
  '',
  'If it contains an `error`: report it briefly to the same destination — but check your recent conversation first and stay silent if you already reported the same error and nothing changed.',
  '',
  'Do not run the scrape scripts yourself. Details: CLAUDE.local.md.',
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
  fs.writeFileSync(path.resolve('groups', FOLDER, 'CLAUDE.local.md'), instructions + '\n');
  fs.writeFileSync(path.resolve('groups', FOLDER, 'gate.sh'), gateScript);

  // 2. Container config: the gate needs python3 (scrape scripts are stdlib-only).
  ensureContainerConfig(ag.id);
  updateContainerConfigJson(ag.id, 'packages_apt', ['python3']);
  console.log('Container config: packages_apt = ["python3"]');

  // 3. Synthetic CLI messaging group + wiring (session host only).
  let mg: MessagingGroup | undefined = getMessagingGroupByPlatform(CLI_CHANNEL, CLI_PLATFORM_ID);
  if (!mg) {
    mg = {
      id: generateId('mg'),
      channel_type: CLI_CHANNEL,
      platform_id: CLI_PLATFORM_ID,
      name: 'car-finder (scheduler)',
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

  // 5. Recurring gated task. First fire +15min so OneCLI auth, the Telegram
  // destination, and the user's pending car-finder push land first.
  const inDb = openInboundDb(ag.id, session.id);
  try {
    const live = inDb
      .prepare("SELECT COUNT(*) c FROM messages_in WHERE kind='task' AND status IN ('pending','paused')")
      .get() as { c: number };
    if (live.c > 0) {
      console.log(`Live task already present (${live.c}); not inserting a duplicate.`);
    } else {
      const processAfter = new Date(Date.now() + 15 * 60_000).toISOString();
      insertTask(inDb, {
        id: generateId('task'),
        processAfter,
        recurrence: RECURRENCE,
        platformId: CLI_PLATFORM_ID,
        channelType: CLI_CHANNEL,
        threadId: null,
        // scriptTimeoutSeconds: scrape sleeps between requests; 30s default
        // is far too short (see task-script.ts per-task override).
        content: JSON.stringify({ prompt: TASK_PROMPT, script: gateScript, scriptTimeoutSeconds: 900 }),
      });
      console.log(`Inserted recurring task (first fire ${processAfter}, cron ${RECURRENCE})`);
    }
  } finally {
    inDb.close();
  }

  console.log('');
  console.log('Next steps:');
  console.log(`  onecli agents create --identifier ${ag.id} --name car-finder`);
  console.log('  onecli agents set-secret-mode --id <printed-agent-id> --mode all');
  console.log('  ...then pair the Telegram chat and add the `telegram` destination.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
