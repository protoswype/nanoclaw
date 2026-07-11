#!/usr/bin/env bash
# car-finder pre-task gate — the ENTIRE scrape cycle runs here, no LLM.
#
# Runs inside the agent container before every scheduled fire (every 15 min),
# with the OneCLI proxy env (HTTPS_PROXY + CA bundle), so git-over-HTTPS to
# gitlab.com is auto-authenticated via the injected Basic auth header
# ("Gitlab Git Basic" vault secret). Needs the per-task timeout override
# (scriptTimeoutSeconds) — the scrape sleeps between requests and takes
# minutes, far beyond the 30s default.
#
# Cycle:
#   1. clone (first run) / sync the repo at /workspace/car-finder
#   2. due check: last_run.json timestamp > 1h old (or missing)? no -> skip
#   3. python3 run.py  (repo entrypoint: all searches x all sources + distances)
#   4. commit + push whole tree — push to main triggers the Pages deploy
#   5. last_run.json newOffersFound:
#        false -> {"wakeAgent":false}  (zero LLM spend)
#        true  -> wake with the added offers' details from results.json
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
# The workspace is a host bind mount; uid mismatches (docker exec, host uid
# remaps) otherwise trip git's dubious-ownership refusal.
git config --global --add safe.directory "$DIR" 2>/dev/null || true

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

# --- 2. due check ------------------------------------------------------------
# Fires every 15 min, but a full refresh only runs when the last completed
# cycle (last_run.json `timestamp`, committed with every run — also by the
# user's local runs) is more than 1h old. Missing/unreadable counts as due.
# searches.json is read-only config since the multi-source rewrite and holds
# no schedule state anymore.
due=$(python3 - <<'PY'
import json, datetime
try:
    v = json.load(open("last_run.json"))["timestamp"]
    last = datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
except Exception:
    print("due")
    raise SystemExit(0)
now = datetime.datetime.now(datetime.timezone.utc)
print("due" if (now - last).total_seconds() > 3600 else "skip")
PY
) || fail "due check failed"

if [ "$due" != "due" ]; then
  echo '{"wakeAgent": false, "data": {}}'
  exit 0
fi

# --- 3. run the cycle --------------------------------------------------------
# run.py is the repo's stable entrypoint contract: all searches on all
# sources + distances, no arguments. Internal script layout may change.
python3 run.py >>"$LOG" 2>&1
rc=$?
[ "$rc" -eq 2 ] && fail "every scrape source blocked or layout changed (exit 2) — previous results kept"
[ "$rc" -ne 0 ] && fail "run failed (exit $rc)"

# --- 4. publish --------------------------------------------------------------
# Whole tree, not a file list — the run mutates results, report and caches
# (distance_cache.json, mobile_refdata_cache.json, ...) and the set may grow.
git add -A >>"$LOG" 2>&1
if ! git diff --cached --quiet; then
  git commit -m "update results $(date -u +%F_%H%M)" >>"$LOG" 2>&1 || fail "git commit failed"
  git push origin main >>"$LOG" 2>&1 || fail "git push failed"
fi

# --- 5. wake decision --------------------------------------------------------
# last_run.json is the documented automation contract and — since the
# multi-source rewrite — reports the WHOLE cycle (all searches, all sources).
# Offer details for the added ids come from results.json.
# sourceFailures alone never wakes: mobile.de is macOS-only (Akamai TLS
# fingerprint) and fails on every containerized run by design.
python3 - "$PAGES_URL" <<'PY' || fail "reading last_run.json/results.json failed"
import json, sys

lr = json.load(open("last_run.json"))
if not lr.get("newOffersFound"):
    print(json.dumps({"wakeAgent": False, "data": {}}))
    raise SystemExit(0)

added = set(lr.get("added") or [])
offers = []
seen = set()
res = json.load(open("public/results.json"))
for sid, block in res.get("searches", {}).items():
    for o in block.get("offers", []):
        oid = o.get("offerId")
        if oid in added and oid not in seen:
            seen.add(oid)
            offers.append({
                "offerId": oid,
                "searchId": sid,
                "searchName": (block.get("spec") or {}).get("name"),
                "source": o.get("source"),
                "title": o.get("title"),
                "price": o.get("priceRaw") or o.get("price"),
                "kilometerstand": o.get("kilometerstand"),
                "erstzulassungsjahr": o.get("erstzulassungsjahr"),
                "city": o.get("city"),
                "distanceFromHome": o.get("distanceFromHome"),
                "travelTimeMinutes": o.get("travelTimeMinutes"),
                "link": o.get("link"),
                "altLink": o.get("altLink"),
            })

print(json.dumps({"wakeAgent": True, "data": {
    "added": sorted(added),
    "totalOffers": lr.get("totalOffers"),
    "sourceFailures": lr.get("sourceFailures") or [],
    "offers": offers,
    "pagesUrl": sys.argv[1],
}}))
PY
