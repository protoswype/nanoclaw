/**
 * Pause / resume / inspect an agent group's recurring scheduler.
 *
 * The scheduler is NOT an OneCLI concept — it's the recurring `kind='task'`
 * rows in the agent group's session inbound.db. Pausing flips them to
 * 'paused' so the host stops waking the container; resuming flips them back
 * to 'pending' (next sweep re-fires). A container mid-run is unaffected.
 *
 * Usage:
 *   pnpm exec tsx scripts/scheduler-ctl.ts <agent-group-name> <status|pause|resume>
 *   e.g. pnpm exec tsx scripts/scheduler-ctl.ts ai-life-coach_po-epic-refiner status
 */
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { findSessionByAgentGroup } from '../src/db/sessions.js';
import { pauseTask, resumeTask } from '../src/modules/scheduling/db.js';
import { openInboundDb } from '../src/session-manager.js';

type Row = { id: string; series_id: string; status: string; process_after: string | null; recurrence: string | null };

function main(): void {
  const [name, action = 'status'] = process.argv.slice(2);
  if (!name || !['status', 'pause', 'resume'].includes(action)) {
    console.error('Usage: scheduler-ctl.ts <agent-group-name> <status|pause|resume>');
    process.exit(2);
  }

  const db = initDb(path.join(DATA_DIR, 'v2.db'));
  const ag = db.prepare('SELECT id, name FROM agent_groups WHERE name = ?').get(name) as
    | { id: string; name: string }
    | undefined;
  if (!ag) {
    console.error(`No agent group named "${name}". Available:`);
    for (const g of db.prepare('SELECT name FROM agent_groups ORDER BY name').all() as Array<{ name: string }>)
      console.error('  - ' + g.name);
    process.exit(1);
  }

  const session = findSessionByAgentGroup(ag.id);
  if (!session) {
    console.error(`No session for agent group "${name}" — nothing scheduled yet.`);
    process.exit(1);
  }

  const inDb = openInboundDb(ag.id, session.id);
  try {
    const tasks = () =>
      inDb
        .prepare("SELECT id, series_id, status, process_after, recurrence FROM messages_in WHERE kind='task' ORDER BY process_after")
        .all() as Row[];

    if (action !== 'status') {
      const wantFrom = action === 'pause' ? 'pending' : 'paused';
      const series = [...new Set(tasks().filter((t) => t.status === wantFrom).map((t) => t.series_id))];
      for (const s of series) (action === 'pause' ? pauseTask : resumeTask)(inDb, s);
      console.log(`${action === 'pause' ? 'Paused' : 'Resumed'} ${series.length} scheduler series for "${name}".`);
    }

    const live = tasks().filter((t) => t.status === 'pending' || t.status === 'paused');
    console.log(`Scheduler for "${name}" (${live.length} live occurrence(s)):`);
    for (const t of live)
      console.log(`  [${t.status}] next=${t.process_after ?? '—'}  cron=${t.recurrence ?? 'one-shot'}  (${t.id})`);
    if (!live.length) console.log('  (no pending/paused tasks)');
  } finally {
    inDb.close();
  }
}

main();
