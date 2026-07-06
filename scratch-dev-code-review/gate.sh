#!/usr/bin/env bash
# dev-code-review pre-task gate.
# Runs inside the agent container before every scheduled fire. Has the
# OneCLI proxy env (HTTPS_PROXY + CA + CURL_CA_BUNDLE) so curl to gitlab.com
# is auto-authenticated with the PRIVATE-TOKEN header. Hard 30s budget.
#
# Decision (first actionable story wins -> one wake per fire):
#   Stories labeled status::in-review, NOT human-needed, state=opened,
#   oldest first. The first such story -> action=review.
#   The label transition the agent performs (status::done on success,
#   status::in-implementation on rework needed, or human-needed when blocked)
#   removes the story from this set.
#
# Branch is deterministic: feature/<iid>. Resolves the existing branch, plan
# file, review artifact, and primary MR and passes them through.
#
# Emits a single final JSON line: {"wakeAgent":bool,"data":{...}}.
# Nothing actionable -> wakeAgent=false -> no LLM spend.
set -uo pipefail

cat > /tmp/dev-code-review-gate.js <<'NODE'
const cp = require('child_process');
const PID = 84091630;
const API = 'https://gitlab.com/api/v4';

function curlRun(extra) {
  try {
    return cp.execFileSync('curl', ['-sS', '--max-time', '18', ...extra], { maxBuffer: 8e6 }).toString();
  } catch (e) {
    return cp.execFileSync('curl', ['-sS', '-k', '--max-time', '18', ...extra], { maxBuffer: 8e6 }).toString();
  }
}
function curlGet(url) { return curlRun([url]); }
function out(wake, data) { console.log(JSON.stringify({ wakeAgent: wake, data })); process.exit(0); }

let stories;
try {
  // status::in-review (%3A%3A = '::'), NOT human-needed, opened, oldest first
  stories = JSON.parse(curlGet(
    `${API}/projects/${PID}/issues?labels=status%3A%3Ain-review&not[labels]=human-needed&state=opened&per_page=100&order_by=created_at&sort=asc`
  ));
} catch (e) {
  out(false, { error: 'fetch stories failed: ' + String(e && e.message || e).slice(0, 140) });
}

if (!Array.isArray(stories) || stories.length === 0) {
  out(false, { note: 'no in-review stories found', raw: typeof stories === 'string' ? stories.slice(0, 200) : null });
}

const story = stories[0];
const branch = `feature/${story.iid}`;

// Does the branch exist in the main project?
let branchExists = false;
try {
  const b = JSON.parse(curlGet(`${API}/projects/${PID}/repository/branches/${encodeURIComponent(branch)}`));
  branchExists = !!(b && b.name === branch);
} catch (e) { branchExists = false; }

// Does the approved plan file exist on that branch?
let planExists = false;
if (branchExists) {
  const planPath = `delivery%2Fdev-plans%2Fissue-${story.iid}%2FPLAN.md`;
  try {
    const raw = curlGet(`${API}/projects/${PID}/repository/files/${planPath}/raw?ref=${encodeURIComponent(branch)}`);
    planExists = !!raw && !/^\s*\{\s*"message"\s*:/.test(raw);
  } catch (e) { planExists = false; }
}

// Does a review artifact already exist on that branch?
let reviewExists = false;
if (branchExists) {
  const reviewPath = `delivery%2Fdev-reviews%2Fissue-${story.iid}%2FREVIEW.md`;
  try {
    const raw = curlGet(`${API}/projects/${PID}/repository/files/${reviewPath}/raw?ref=${encodeURIComponent(branch)}`);
    reviewExists = !!raw && !/^\s*\{\s*"message"\s*:/.test(raw);
  } catch (e) { reviewExists = false; }
}

// Resolve the primary MR.
let mrIid = null, mrBranch = null, mrWebUrl = null;
try {
  const mrs = JSON.parse(curlGet(
    `${API}/projects/${PID}/merge_requests?state=opened&source_branch=${encodeURIComponent(branch)}&per_page=20`
  ));
  if (Array.isArray(mrs) && mrs.length) {
    const mr = mrs[0];
    mrIid = mr.iid; mrBranch = mr.source_branch; mrWebUrl = mr.web_url;
  }
} catch (e) { /* leave null */ }

out(true, {
  action: 'review',
  storyIid: story.iid,
  storyTitle: story.title,
  storyDescription: story.description,
  storyLabels: story.labels,
  branch,
  branchExists,
  planExists,
  reviewExists,
  mrIid,
  mrBranch,
  mrWebUrl,
});
NODE

node /tmp/dev-code-review-gate.js
