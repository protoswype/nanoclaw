PID=84091630
echo "--- SRS-001 wiki notes now ---"
curl -sS -H 'Content-Type: application/json' -X POST --data '{"query":"{ project(fullPath:\"protoswype-group/life-coach/ai-life-coach-business\"){ wikiPages(first:100){ nodes{ slug notes{ nodes{ author{username} createdAt body } } } } } }"}' https://gitlab.com/api/graphql | python3 -c 'import sys,json
for n in json.load(sys.stdin)["data"]["project"]["wikiPages"]["nodes"]:
  for nt in (n["notes"]["nodes"] or []):
    if "srs" in n["slug"]: print(" ",n["slug"],"|",nt["author"]["username"],"|",nt["body"][:60].replace("\n"," "))' 2>/dev/null
echo "--- write test: create+destroy wiki note ---"
R=$(curl -sS -H 'Content-Type: application/json' -X POST --data '{"query":"mutation { createNote(input:{noteableId:\"gid://gitlab/WikiPage::Meta/6365911\", body:\"probe (self-delete)\"}){ note{ id } errors } }"}' https://gitlab.com/api/graphql)
echo "  create: $R"
NID=$(echo "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["data"]["createNote"]["note"]["id"] if d.get("data",{}).get("createNote",{}).get("note") else "")' 2>/dev/null)
[ -n "$NID" ] && curl -sS -H 'Content-Type: application/json' -X POST --data "{\"query\":\"mutation { destroyNote(input:{id:\\\"$NID\\\"}){ errors } }\"}" https://gitlab.com/api/graphql >/dev/null && echo "  destroyed ok"
echo "--- write test: create+delete issue ---"
IID=$(curl -sS -X POST "https://gitlab.com/api/v4/projects/$PID/issues" --data-urlencode "title=[PROBE] delete me" --data "issue_type=issue" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("iid",""))' 2>/dev/null)
echo "  created iid=$IID"
[ -n "$IID" ] && echo "  delete: $(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "https://gitlab.com/api/v4/projects/$PID/issues/$IID")"
