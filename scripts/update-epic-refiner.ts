/**
 * Push updated CLAUDE.local.md + gate script into the live po-epic-refiner
 * agent group and its running recurring task.
 *
 * Usage: pnpm exec tsx scripts/update-epic-refiner.ts
 */
import fs from 'fs';
import path from 'path';

import { DATA_DIR } from '../src/config.js';
import { getAgentGroupByFolder } from '../src/db/agent-groups.js';
import { initDb } from '../src/db/connection.js';
import { updateTask } from '../src/modules/scheduling/db.js';
import { findSessionByAgentGroup } from '../src/db/sessions.js';
import { openInboundDb } from '../src/session-manager.js';

const FOLDER = 'ai-life-coach_po-epic-refiner';
const SCRATCH = path.resolve('scratch-epic-refiner');

function main(): void {
  const instructions = fs.readFileSync(path.join(SCRATCH, 'CLAUDE.md'), 'utf8');
  const gateScript = fs.readFileSync(path.join(SCRATCH, 'gate.sh'), 'utf8');

  initDb(path.join(DATA_DIR, 'v2.db'));
  const ag = getAgentGroupByFolder(FOLDER);
  if (!ag) throw new Error(`agent group ${FOLDER} not found`);

  fs.writeFileSync(path.resolve('groups', FOLDER, 'CLAUDE.local.md'), instructions + '\n');
  fs.writeFileSync(path.resolve('groups', FOLDER, 'gate.sh'), gateScript);
  console.log('Refreshed groups/' + FOLDER + '/{CLAUDE.local.md,gate.sh}');

  const session = findSessionByAgentGroup(ag.id);
  if (!session) throw new Error('no session for agent group');
  const inDb = openInboundDb(ag.id, session.id);
  try {
    const rows = inDb
      .prepare("SELECT DISTINCT series_id FROM messages_in WHERE kind='task' AND status IN ('pending','paused')")
      .all() as Array<{ series_id: string }>;
    let touched = 0;
    for (const r of rows) touched += updateTask(inDb, r.series_id, { script: gateScript });
    console.log(`Updated gate script on ${touched} live task row(s) across ${rows.length} series.`);
  } finally {
    inDb.close();
  }
}

main();
