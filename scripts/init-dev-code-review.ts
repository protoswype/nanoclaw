/**
 * Bootstrap the `dev-code-review` autonomous agent group.
 *
 * Fourth stage of the pipeline: po-story-refiner -> dev-plan -> dev-implement -> dev-code-review.
 * Acts on stories a human (or dev-implement) promoted to `status::in-review` (and cleared
 * of `human-needed`): reads the approved plan, reads the implementation on the existing
 * `dev-plan/issue-<iid>` branch via the REST API, commits a review artifact, and moves
 * the story to `status::done` (passed), `status::in-implementation` (needs rework), or
 * `human-needed` (blocked on human input). All output goes to GitLab — no chat channel.
 *
 * Creates the agent group + filesystem, a synthetic `cli:dev-code-review`
 * messaging group + wiring (session host only), an active session, and injects
 * a recurring task (every 15 min) whose pre-task gate polls GitLab and only
 * wakes the LLM when one story is actionable.
 *
 * Sets the model to claude-sonnet-4-6 in container_configs.
 *
 * Safe to re-run: reuses group/mg/wiring/session if present, refuses to
 * insert a duplicate live task.
 *
 * After this runs, provision the OneCLI agent for GitLab auth:
 *   onecli agents create --identifier <group-id> --name dev-code-review
 *   onecli agents set-secret-mode --id <onecli-agent-id> --mode all
 *
 * Usage: pnpm exec tsx scripts/init-dev-code-review.ts
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

const FOLDER = 'ai-life-coach_dev-code-review';
const CLI_CHANNEL = 'cli';
const CLI_PLATFORM_ID = 'dev-code-review';
const SCRATCH = path.resolve('scratch-dev-code-review');
const MODEL = 'claude-sonnet-4-6';

const TASK_PROMPT = [
  'Scheduled dev-code-review scan.',
  '',
  'The pre-task gate has already selected exactly ONE actionable item and passed it as `Script output` above: an object { action, storyIid, storyTitle, storyDescription?, storyLabels?, branch, branchExists, planExists, reviewExists, mrIid?, mrBranch?, mrWebUrl? }.',
  '',
  'Follow your workflow (CLAUDE.local.md) and perform ONLY the single `action` (review) for that one story, then stop. Load the delivery/dev-code-reviewer skill and the approved plan first. Real git works through the gateway: clone the repos, checkout the EXISTING plan branch (from dev-plan), install deps, build + test (never skip), review the implementation against the plan, write the review artifact (delivery/dev-reviews/issue-<iid>/REVIEW.md), then commit and `git push` (one push per repo). Link the story in every commit message (`Ref #<iid>`). Metadata (issues, MR notes, labels) via curl REST. Prefix every comment with `<!-- dev-code-review:auto -->` and @mention @protoswype-group/life-coach on human-facing comments. On success: `add_labels=status::done&remove_labels=status::in-review`. On rework needed: `add_labels=status::in-implementation&remove_labels=status::in-review`. On human blocked: `add_labels=human-needed` only (leave status::in-review). Auto-swap of scoped labels is unreliable — always set both add and remove explicitly.',
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

  // 2. Set model in container_configs.
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
      name: 'dev-code-review (scheduler)',
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
  console.log(`Agent group id: ${ag.id}`);
  console.log('Next: provision OneCLI GitLab auth for this agent:');
  console.log(`  onecli agents create --identifier ${ag.id} --name dev-code-review`);
  console.log(`  onecli agents set-secret-mode --id <printed-agent-id> --mode all`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
