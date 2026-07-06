/**
 * Pause / resume / inspect EVERY agent group's recurring scheduler at once.
 *
 * Schedulers are the recurring `kind='task'` rows in each session's
 * inbound.db (not an OneCLI concept). This walks all active sessions,
 * flips their live task series, and reports per group. A container mid-run
 * is unaffected; pause just stops the host from waking it again.
 *
 * Usage:
 *   pnpm exec tsx scripts/scheduler-all.ts <status|pause|resume>
 */
import fs from 'fs';
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { initDb } from '../src/db/connection.js';
import { getActiveSessions } from '../src/db/sessions.js';
import { pauseTask, resumeTask } from '../src/modules/scheduling/db.js';
import { inboundDbPath, openInboundDb } from '../src/session-manager.js';

type Row = { id: string; series_id: string; status: string; process_after: string | null; recurrence: string | null };

function main(): void {
  const action = process.argv[2] ?? 'status';
  if (!['status', 'pause', 'resume'].includes(action)) {
    console.error('Usage: scheduler-all.ts <status|pause|resume>');
    process.exit(2);
  }

  const db = initDb(path.join(DATA_DIR, 'v2.db'));
  const names = new Map<string, string>();
  for (const g of db.prepare('SELECT id, name FROM agent_groups').all() as Array<{ id: string; name: string }>)
    names.set(g.id, g.name);

  let totalGroups = 0;
  let totalTouched = 0;

  for (const s of getActiveSessions()) {
    if (!fs.existsSync(inboundDbPath(s.agent_group_id, s.id))) continue;
    const inDb = openInboundDb(s.agent_group_id, s.id);
    try {
      const tasks = () =>
        inDb
          .prepare("SELECT id, series_id, status, process_after, recurrence FROM messages_in WHERE kind='task' ORDER BY process_after")
          .all() as Row[];

      const live = () => tasks().filter((t) => t.status === 'pending' || t.status === 'paused');
      if (live().length === 0) continue;
      totalGroups++;
      const label = names.get(s.agent_group_id) ?? s.agent_group_id;

      if (action !== 'status') {
        const from = action === 'pause' ? 'pending' : 'paused';
        const series = [...new Set(tasks().filter((t) => t.status === from).map((t) => t.series_id))];
        for (const ser of series) totalTouched += (action === 'pause' ? pauseTask : resumeTask)(inDb, ser) ?? 0;
      }

      console.log(`• ${label}`);
      for (const t of live())
        console.log(`    [${t.status}] next=${t.process_after ?? '—'}  cron=${t.recurrence ?? 'one-shot'}  (${t.id})`);
    } finally {
      inDb.close();
    }
  }

  if (totalGroups === 0) {
    console.log('No agent groups have live schedules.');
  } else if (action !== 'status') {
    console.log(`\n${action === 'pause' ? 'Paused' : 'Resumed'} schedules across ${totalGroups} group(s).`);
  }
}

main();
