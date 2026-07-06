#!/usr/bin/env bash
# dev-plan pre-task gate.
# Runs inside the agent container before every scheduled fire. Has the
# OneCLI proxy env (HTTPS_PROXY + CA + CURL_CA_BUNDLE) so curl to gitlab.com
# is auto-authenticated with the PRIVATE-TOKEN header. Hard 30s budget.
#
# Decision (first actionable story wins → one wake per fire):
#   1) Stories labeled status::ready, NOT human-needed, state=opened.
#      No open MR with source branch feature/<iid> → create-plan
#      Open dev-plan MR with human comment newer than last agent comment  → apply-feedback
#
# Emits a single final JSON line: {"wakeAgent":bool,"data":{...}}.
# Nothing actionable → wakeAgent=false → no LLM spend.
set -uo pipefail

cat > /tmp/dev-plan-gate.js <<'NODE'
const cp = require('child_process');
const PID = 84091630;
const API = 'https://gitlab.com/api/v4';
const SVC = 'service_account_group_132351839_1ff0c21ae8ca2e64aa6baf6f05cd8153';
const MARK = '<!-- dev-plan:auto -->';

function curlRun(extra) {
  try {
    return cp.execFileSync('curl', ['-sS', '--max-time', '18', ...extra], { maxBuffer: 8e6 }).toString();
  } catch (e) {
    return cp.execFileSync('curl', ['-sS', '-k', '--max-time', '18', ...extra], { maxBuffer: 8e6 }).toString();
  }
}
function curlGet(url) { return curlRun([url]); }
function out(wake, data) { console.log(JSON.stringify({ wakeAgent: wake, data })); process.exit(0); }
const isAgent = n => (n.author && n.author.username === SVC) || (n.body || '').includes(MARK);

let stories;
try {
  // status::ready (%3A%3A = '::'), NOT human-needed, opened — sorted oldest first
  stories = JSON.parse(curlGet(
    `${API}/projects/${PID}/issues?labels=status%3A%3Aready&not[labels]=human-needed&state=opened&per_page=100&order_by=created_at&sort=asc`
  ));
} catch (e) {
  out(false, { error: 'fetch stories failed: ' + String(e && e.message || e).slice(0, 140) });
}

if (!Array.isArray(stories) || stories.length === 0) {
  out(false, { note: 'no ready stories found', raw: typeof stories === 'string' ? stories.slice(0, 200) : null });
}

for (const story of stories) {
  let relatedMrs;
  try {
    relatedMrs = JSON.parse(curlGet(`${API}/projects/${PID}/issues/${story.iid}/related_merge_requests`));
  } catch (e) {
    continue;
  }
  if (!Array.isArray(relatedMrs)) relatedMrs = [];

  // Branch is deterministic: feature/<iid>
  const branch = `feature/${story.iid}`;
  const agentMrs = relatedMrs.filter(
    mr => mr.state === 'opened' && mr.source_branch === branch
  );

  if (agentMrs.length === 0) {
    // No linked dev-plan branch/MR → create a plan
    out(true, {
      action: 'create-plan',
      storyIid: story.iid,
      storyTitle: story.title,
      storyDescription: story.description,
      storyLabels: story.labels,
    });
  }

  // MR exists — check for human feedback newer than last agent comment
  const mr = agentMrs[0];
  let notes;
  try {
    notes = JSON.parse(curlGet(
      `${API}/projects/${PID}/merge_requests/${mr.iid}/notes?per_page=100&sort=asc`
    ));
  } catch (e) {
    continue;
  }
  if (!Array.isArray(notes)) continue;

  const agentNotes = notes.filter(n => isAgent(n) && !n.system);
  const humanNotes = notes.filter(n => !isAgent(n) && !n.system);

  const lastAgent = agentNotes.length ? Math.max(...agentNotes.map(n => +new Date(n.created_at))) : 0;
  const lastHuman = humanNotes.length ? Math.max(...humanNotes.map(n => +new Date(n.created_at))) : 0;

  if (humanNotes.length > 0 && lastHuman > lastAgent) {
    out(true, {
      action: 'apply-feedback',
      storyIid: story.iid,
      storyTitle: story.title,
      mrIid: mr.iid,
      mrBranch: mr.source_branch,
      mrWebUrl: mr.web_url,
    });
  }
}

out(false, { note: 'nothing actionable', checkedStories: stories.map(s => s.iid) });
NODE

node /tmp/dev-plan-gate.js
