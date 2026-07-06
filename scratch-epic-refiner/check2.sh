curl -sS -H 'Content-Type: application/json' -X POST --data '{"query":"{ project(fullPath:\"protoswype-group/life-coach/ai-life-coach-business\"){ wikiPages(first:100){ nodes{ slug notes{ nodes{ author{username} createdAt body } } } } } }"}' https://gitlab.com/api/graphql > /tmp/gq.json
python3 - <<'PY'
import json
d=json.load(open("/tmp/gq.json"))
if "errors" in d: print("GQL ERROR:", d["errors"][0]["message"][:120]); raise SystemExit
proj=d.get("data",{}).get("project")
if not proj: print("project null (auth?)"); raise SystemExit
for n in proj["wikiPages"]["nodes"]:
    if "srs" not in n["slug"]: continue
    notes=n["notes"]["nodes"] or []
    print(n["slug"], "->", len(notes), "notes")
    for nt in notes: print("    ", nt["author"]["username"], nt["createdAt"], repr(nt["body"][:80]))
PY
