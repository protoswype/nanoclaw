#!/usr/bin/env bash
# car-finder pre-task gate — the ENTIRE hourly cycle runs here, no LLM.
#
# Runs inside the agent container before every scheduled fire, with the
# OneCLI proxy env (HTTPS_PROXY + CA bundle), so git-over-HTTPS to gitlab.com
# is auto-authenticated via the injected Basic auth header ("Gitlab Git
# Basic" vault secret). Needs the per-task timeout override
# (scriptTimeoutSeconds) — the scrape sleeps between requests and takes
# minutes, far beyond the 30s default.
#
# Cycle:
#   1. clone (first run) / sync the repo at /workspace/car-finder
#   2. python3 run.py   (falls back to search.py + distance.py on old checkouts)
#   3. commit + push state/results — push to main triggers the Pages deploy
#   4. read last_run.json:
#        newOffersFound=false -> {"wakeAgent":false}  (zero LLM spend)
#        newOffersFound=true  -> wake with the new offers' details
#   Any failure wakes the agent with {"error": ...} so it can report it.
#
# Emits exactly one final JSON line: {"wakeAgent":bool,"data":{...}}.
set -uo pipefail

REPO_URL="https://gitlab.com/protoswype-group/car-finder.git"
DIR="/workspace/car-finder"
PAGES_URL="https://protoswype-group.gitlab.io/car-finder/"
LOG=/tmp/car-finder-run.log
: > "$LOG"

fail() {
  local msg="$1"
  python3 - "$msg" <<'PY' 2>/dev/null && exit 0
import json, sys
tail = ""
try:
    tail = open("/tmp/car-finder-run.log", errors="replace").read()[-1500:]
except Exception:
    pass
print(json.dumps({"wakeAgent": True, "data": {"error": sys.argv[1], "log": tail}}))
PY
  # python3 itself missing/broken — last-resort plain echo
  printf '{"wakeAgent":true,"data":{"error":"%s (and python3 unavailable)"}}\n' "$msg"
  exit 0
}

command -v git >/dev/null || fail "git not installed in container"
command -v python3 >/dev/null || fail "python3 not installed in container (packages_apt)"

# All HTTPS goes through the OneCLI MITM proxy, but only Node gets its CA
# via env (NODE_EXTRA_CA_CERTS). git, python3 (urllib/ssl) and curl each
# read different variables — export them all or clone/scrape/push fail
# certificate verification. Prefer the combined bundle (gateway CA + system
# CAs) so non-MITM'd hosts keep verifying too.
for ca in /tmp/onecli-combined-ca.pem "${NODE_EXTRA_CA_CERTS:-}" /tmp/onecli-gateway-ca.pem; do
  if [ -n "$ca" ] && [ -f "$ca" ]; then
    export GIT_SSL_CAINFO="$ca" SSL_CERT_FILE="$ca" CURL_CA_BUNDLE="$ca" REQUESTS_CA_BUNDLE="$ca"
    break
  fi
done

# --- 1. clone / sync ---------------------------------------------------------
if [ ! -d "$DIR/.git" ]; then
  git clone "$REPO_URL" "$DIR" >>"$LOG" 2>&1 || fail "git clone failed"
  git -C "$DIR" config user.name "car-finder-bot"
  git -C "$DIR" config user.email "car-finder-bot@nanoclaw.local"
fi
cd "$DIR" || fail "workspace dir missing"
git fetch origin main >>"$LOG" 2>&1 || fail "git fetch failed"
# Tree should always be clean (every run commits everything). If a previous
# run died mid-way or the remote diverged, remote wins — losing at most one
# cycle's state, which the next scrape heals (README: idempotent).
git pull --rebase origin main >>"$LOG" 2>&1 || {
  git rebase --abort >>"$LOG" 2>&1
  git reset --hard origin/main >>"$LOG" 2>&1 || fail "git sync failed"
}

# --- 2. run the cycle --------------------------------------------------------
if [ -f run.py ]; then
  python3 run.py >>"$LOG" 2>&1
  rc=$?
else
  python3 search.py >>"$LOG" 2>&1 && python3 distance.py >>"$LOG" 2>&1
  rc=$?
fi
[ "$rc" -eq 2 ] && fail "scrape blocked or page layout changed (exit 2) — previous results kept"
[ "$rc" -ne 0 ] && fail "run failed (exit $rc)"

# --- 3. publish --------------------------------------------------------------
git add -A searches.json distance_cache.json last_run.json public/ >>"$LOG" 2>&1
if ! git diff --cached --quiet; then
  git commit -m "update results $(date -u +%F_%H%M)" >>"$LOG" 2>&1 || fail "git commit failed"
  git push origin main >>"$LOG" 2>&1 || fail "git push failed"
fi

# --- 4. wake decision --------------------------------------------------------
python3 - "$PAGES_URL" <<'PY' || fail "reading last_run.json/results.json failed"
import json, sys

lr = json.load(open("last_run.json"))
if not lr.get("newOffersFound"):
    print(json.dumps({"wakeAgent": False, "data": {}}))
    raise SystemExit(0)

added = set(lr.get("added") or [])
offers = []
res = json.load(open("public/results.json"))
for sid, block in res.get("searches", {}).items():
    for o in block.get("offers", []):
        if o.get("offerId") in added:
            offers.append({
                "searchId": sid,
                "searchName": (block.get("spec") or {}).get("name"),
                "title": o.get("title"),
                "price": o.get("priceRaw") or o.get("price"),
                "kilometerstand": o.get("kilometerstand"),
                "erstzulassungsjahr": o.get("erstzulassungsjahr"),
                "city": o.get("city"),
                "distanceFromHome": o.get("distanceFromHome"),
                "travelTimeMinutes": o.get("travelTimeMinutes"),
                "link": o.get("link"),
            })

print(json.dumps({"wakeAgent": True, "data": {
    "searchId": lr.get("searchId"),
    "added": sorted(added),
    "totalOffers": lr.get("totalOffers"),
    "offers": offers,
    "pagesUrl": sys.argv[1],
}}))
PY
