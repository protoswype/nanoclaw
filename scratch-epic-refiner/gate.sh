#!/usr/bin/env bash
# po-epic-refiner pre-task gate.
# Runs inside the agent container before every scheduled fire. It has the
# OneCLI proxy env (HTTPS_PROXY + CA + CURL_CA_BUNDLE) so curl to gitlab.com
# is auto-authenticated with the PRIVATE-TOKEN header. Hard 30s budget.
#
# The token belongs to the GitLab service account `claw`
# (service_account_group_132351839_...). Agent-authored comments are detected
# by that author identity (marker kept as a fallback). A comment by any other
# author is human. Approval = a ✅ (white_check_mark) award emoji placed by a
# non-service (human) user on the latest "Epics Proposal".
#
# Decision (first actionable item wins -> one wake per fire):
#   1) Validated SRS wiki pages:
#      - no proposal                              -> propose
#      - proposal approved (✅) & no "Epics Created" comment -> create-epics
#      - proposal approved (✅) & "Epics Created" comment    -> settled, skip
#      - proposal not approved & newer human comment         -> adapt-proposal
#      - proposal not approved & no newer human comment       -> skip
#   2) Draft epics (GitLab issue, type=issue, state=opened, label `status:draft`,
#      NOT label `human-needed`) with no agent comment yet OR a human comment
#      newer than the last agent comment                      -> refine-epic
#
# Label semantics (status:draft / human-needed) are intentionally duplicated
# here for scripting. The agent-execute side must NOT re-derive them — it loads
# the project epic-refiner skill, which owns epic shape + labels.
#
# Emits a single final JSON line: {"wakeAgent":bool,"data":{...}}.
# Everything settled -> wakeAgent=false -> no LLM spend.
set -uo pipefail

cat > /tmp/epic-gate.js <<'NODE'
const cp = require('child_process');
const PID = 84091630;
const PP = 'protoswype-group/life-coach/ai-life-coach-business';
const API = `https://gitlab.com/api/v4`;
const GQL = 'https://gitlab.com/api/graphql';
const SVC = 'service_account_group_132351839_1ff0c21ae8ca2e64aa6baf6f05cd8153';
const MARK = '<!-- po-epic-refiner:auto -->';

// The OneCLI CA is normally bind-mounted for cert verification. On a spawn
// race the mount can land as an empty dir (curl error 60/77) — in that case
// fall back to -k (verification skipped; the proxy is localhost and the token
// is injected there, so this only affects TLS-verify of the local gateway).
function curlRun(extra) {
  try {
    return cp.execFileSync('curl', ['-sS', '--max-time', '18', ...extra], { maxBuffer: 8e6 }).toString();
  } catch (e) {
    return cp.execFileSync('curl', ['-sS', '-k', '--max-time', '18', ...extra], { maxBuffer: 8e6 }).toString();
  }
}
function curlGet(url) { return curlRun([url]); }
function curlPost(url, data) {
  return curlRun(['-X', 'POST', '-H', 'Content-Type: application/json', '--data', data, url]);
}
function out(wake, data) { console.log(JSON.stringify({ wakeAgent: wake, data })); process.exit(0); }

// Agent-authored? by service-account identity, or (fallback) the marker.
const isAgent = n => (n.author && n.author.username === SVC) || (n.body || '').includes(MARK);

let wikis, gql, draftEpics;
try {
  wikis = JSON.parse(curlGet(`${API}/projects/${PID}/wikis?with_content=true`));
  const q = { query: `{ project(fullPath:"${PP}"){ wikiPages(first:100){ nodes{ slug notes{ nodes{ body createdAt author{username} awardEmoji{nodes{name user{username}}} } } } } } }` };
  gql = JSON.parse(curlPost(GQL, JSON.stringify(q)));
  // Draft epics: type issue, open, label status:draft (%3A = ':'). human-needed filtered below.
  draftEpics = JSON.parse(curlGet(`${API}/projects/${PID}/issues?issue_type=issue&labels=status%3Adraft&state=opened&per_page=100`));
} catch (e) {
  out(false, { error: 'fetch failed: ' + String(e && e.message || e).slice(0, 140) });
}

// Validated SRS wiki pages.
const srs = (Array.isArray(wikis) ? wikis : [])
  .filter(p => /\/srs\//.test(p.slug) && /status:\s*validated/i.test(p.content || ''))
  .map(p => ({
    slug: p.slug,
    meta: p.wiki_page_meta_id,
    id: ((p.content || '').match(/id:\s*(SRS-\d+)/i) || [])[1] || ((p.slug.match(/SRS-\d+/) || [])[0]),
  }))
  .filter(s => s.id)
  .sort((a, b) => a.id.localeCompare(b.id));

const notesBySlug = {};
try {
  for (const n of gql.data.project.wikiPages.nodes) notesBySlug[n.slug] = (n.notes && n.notes.nodes) || [];
} catch { /* leave empty */ }

// 1) SRS proposal / creation / adaptation.
for (const s of srs) {
  const notes = notesBySlug[s.slug] || [];
  const proposals = notes
    .filter(n => isAgent(n) && /epics proposal/i.test(n.body || ''))
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  const latest = proposals[0];

  if (!latest) out(true, { srs: s.id, slug: s.slug, meta: s.meta, action: 'propose' });

  // Approval must come from a human (non-service) user.
  const approved = ((latest.awardEmoji && latest.awardEmoji.nodes) || [])
    .some(a => a.name === 'white_check_mark' && (!a.user || a.user.username !== SVC));

  if (approved) {
    // "Epics Created" wiki comment (agent-authored, at/after the approved proposal)
    // is the done-marker — decoupled from whether the issues still exist/renamed.
    const created = notes.some(n => isAgent(n) && /epics created/i.test(n.body || '')
      && new Date(n.createdAt) >= new Date(latest.createdAt));
    if (!created) out(true, { srs: s.id, slug: s.slug, meta: s.meta, action: 'create-epics' });
    continue; // approved + created -> settled
  }

  const humanNewer = notes.some(n => !isAgent(n) && new Date(n.createdAt) > new Date(latest.createdAt));
  if (humanNewer) out(true, { srs: s.id, slug: s.slug, meta: s.meta, action: 'adapt-proposal' });
  // else: proposal posted, awaiting human ✅ or reply -> not actionable.
}

// 2) Refine draft epics. Label pool = status:draft & !human-needed. Guard on top:
// only fire when there's no agent comment yet (fresh epic) OR a human comment is
// newer than the last agent comment — otherwise the agent would re-comment every
// fire on a draft that neither passed validation nor got blocked.
const validBySrsId = {};
for (const s of srs) validBySrsId[s.id] = s;
const epicList = Array.isArray(draftEpics) ? draftEpics : [];
let capped = 0;
for (const e of epicList) {
  const labels = e.labels || [];
  if (labels.includes('human-needed')) continue;
  let inotes = [];
  try { inotes = JSON.parse(curlGet(`${API}/projects/${PID}/issues/${e.iid}/notes?per_page=100&sort=asc`)); } catch { capped++; continue; }
  const agentT = inotes.filter(n => isAgent(n)).map(n => +new Date(n.created_at));
  const humanT = inotes.filter(n => !isAgent(n) && !n.system).map(n => +new Date(n.created_at));
  const lastAgent = agentT.length ? Math.max(...agentT) : 0;
  const lastHuman = humanT.length ? Math.max(...humanT) : 0;
  if (agentT.length && !(lastHuman > lastAgent)) continue; // agent already replied, nothing new from humans
  const srsId = ((e.description || '').match(/SRS-\d+/) || [])[0]
    || ((e.title || '').match(/SRS-\d+/) || [])[0] || null;
  const s = srsId ? validBySrsId[srsId] : null;
  out(true, { srs: srsId, slug: s ? s.slug : null, meta: s ? s.meta : null, action: 'refine-epic', epicIid: e.iid });
}

out(false, { note: 'nothing actionable', validatedSrs: srs.map(s => s.id), draftEpics: epicList.map(e => e.iid), epicNoteFetchErrors: capped });
NODE

node /tmp/epic-gate.js
