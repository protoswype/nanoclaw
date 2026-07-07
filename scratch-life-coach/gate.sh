#!/usr/bin/env bash
# ai-life-coach pre-task gate (todo-driven).
# Runs inside the agent container before every scheduled fire (every minute).
# It has the OneCLI proxy env (HTTPS_PROXY + CA + CURL_CA_BUNDLE) so curl to
# gitlab.com is auto-authenticated with the PRIVATE-TOKEN header. Hard 30s budget.
#
# The token belongs to the GitLab service account `claw` (protoswype-nanoclaw).
#
# Decision:
#   GET /todos?state=pending. Empty -> wakeAgent=false -> no LLM spend.
#   Otherwise pick the OLDEST pending todo and classify it into one mode + one
#   model, then wake the agent with the full todo context. The agent is the
#   authority on skill selection; `mode` here is only a hint. `model` is NOT a
#   hint — it is locked for the wake (the container model is fixed per query),
#   so the gate must decide it: OPUS only for a story dev-plan; everything else
#   Sonnet. A misclassification can only under-spend, never accidentally Opus.
#
# Modes: srs-refine | epic-or-story | story | plan | implement | review | unclear
#
# Emits a single final JSON line: {"wakeAgent":bool,"data":{...}}.
set -uo pipefail

cat > /tmp/lc-gate.js <<'NODE'
const cp = require('child_process');
const API = 'https://gitlab.com/api/v4';
const GQL = 'https://gitlab.com/api/graphql';
const MAIN_PID = 84091630;
const OPUS = 'claude-opus-4-8';
const SONNET = 'claude-sonnet-4-6';

// OneCLI CA is normally bind-mounted for cert verification. On a spawn race the
// mount can land empty (curl error 60/77) — fall back to -k (verification
// skipped; proxy is localhost and injects the token there, so this only affects
// TLS-verify of the local gateway).
function curlRun(extra) {
  try {
    return cp.execFileSync('curl', ['-sS', '--max-time', '18', ...extra], { maxBuffer: 8e6 }).toString();
  } catch (e) {
    return cp.execFileSync('curl', ['-sS', '-k', '--max-time', '18', ...extra], { maxBuffer: 8e6 }).toString();
  }
}
function getJson(url) { try { return JSON.parse(curlRun([url])); } catch { return null; } }
function gql(query) {
  try {
    return JSON.parse(curlRun(['-X', 'POST', '-H', 'Content-Type: application/json',
      '--data', JSON.stringify({ query }), GQL]));
  } catch { return null; }
}
function out(wake, data) { console.log(JSON.stringify({ wakeAgent: wake, data })); process.exit(0); }

const has = (labels, name) => Array.isArray(labels) && labels.includes(name);

// 1. Pending todos.
let todos;
try {
  todos = JSON.parse(curlRun([`${API}/todos?state=pending&per_page=100`]));
} catch (e) {
  out(false, { error: 'fetch todos failed: ' + String(e && e.message || e).slice(0, 140) });
}
if (!Array.isArray(todos) || todos.length === 0) {
  out(false, { note: 'no pending todos' });
}

// Oldest first (GitLab returns newest first).
todos.sort((a, b) => new Date(a.created_at || a.createdAt || 0) - new Date(b.created_at || b.createdAt || 0));
const t = todos[0];
const tgt = t.target || {};
const tt = t.target_type || '';
const pid = (t.project && t.project.id) || MAIN_PID;
const labels = tgt.labels || [];
const body = t.body || '';

// Resolve the associated story iid + its status label. Stories are the state
// carrier for the dev pipeline; MR loop todos resolve through the branch.
function storyLabels(issuePid, iid) {
  const iss = getJson(`${API}/projects/${issuePid}/issues/${iid}`);
  return (iss && Array.isArray(iss.labels)) ? iss.labels : null;
}

let mode = 'unclear';

if (tt === 'WikiPage::Meta') {
  mode = /\/srs\//i.test(tgt.slug || '') ? 'srs-refine' : 'unclear';
} else if (tt === 'MergeRequest') {
  // Loop hand-offs land here. Prefer the linked story's status; fall back to body.
  const mr = getJson(`${API}/projects/${pid}/merge_requests/${tgt.iid}`);
  const branch = (mr && mr.source_branch) || '';
  const m = branch.match(/feature\/(\d+)/);
  const slabels = m ? storyLabels(MAIN_PID, m[1]) : null;
  if (slabels && has(slabels, 'status::in-review')) mode = 'review';
  else if (slabels && has(slabels, 'status::in-implementation')) mode = 'implement';
  else if (slabels && has(slabels, 'status::ready')) mode = 'implement'; // human approved the plan on the MR
  else if (/start\s+review/i.test(body)) mode = 'review';
  else if (/start\s+implement/i.test(body)) mode = 'implement';
  else mode = 'review';
} else if (tt === 'Issue') {
  if (has(labels, 'status::in-implementation')) mode = 'implement';
  else if (has(labels, 'status::in-review')) mode = 'review';
  else if (has(labels, 'status::ready')) {
    // status::ready is used by both stories and epics. Distinguish by work-item
    // type: a story is a `Task`.
    const q = gql(`{ project(fullPath:"protoswype-group/life-coach/ai-life-coach-business"){ workItems(iid:"${tgt.iid}"){ nodes{ workItemType{ name } } } } }`);
    let typeName = '';
    try { typeName = q.data.project.workItems.nodes[0].workItemType.name || ''; } catch { typeName = ''; }
    if (/task/i.test(typeName)) {
      // Story ready. Genuine planning (Opus) only while no plan MR exists yet.
      // Once the plan MR is up, a new todo here is post-plan — the human
      // approved the plan (or gave feedback) via a mention — so the agent
      // implements/revises on Sonnet. Keeps Opus scoped to first planning.
      const mrs = getJson(`${API}/projects/${MAIN_PID}/merge_requests?state=opened&source_branch=feature%2F${tgt.iid}&per_page=1`);
      mode = (Array.isArray(mrs) && mrs.length > 0) ? 'implement' : 'plan';
    } else {
      mode = 'epic-or-story';
    }
  }
  else if (has(labels, 'status::in-refinement')) mode = 'story';
  else if (has(labels, 'epic')) mode = 'epic-or-story';
  else mode = 'unclear';
}

const model = mode === 'plan' ? OPUS : SONNET;

out(true, {
  mode,
  model,
  todo: {
    id: t.id,
    action: t.action_name,
    target_type: tt,
    target_iid: tgt.iid || null,
    target_slug: tgt.slug || null,
    target_url: t.target_url || null,
    project_id: pid,
    body,
    author: (t.author && t.author.username) || null,
    labels,
  },
});
NODE

node /tmp/lc-gate.js
