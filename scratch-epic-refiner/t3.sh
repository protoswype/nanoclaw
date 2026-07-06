PID=84091630
echo "who: $(curl -sS https://gitlab.com/api/v4/user | python3 -c 'import sys,json;d=json.load(sys.stdin);print("username=",d.get("username"),"id=",d.get("id"),"bot=",d.get("bot"))')"
echo "READ project:   $(curl -sS -o /dev/null -w '%{http_code}' https://gitlab.com/api/v4/projects/$PID)"
ME=$(curl -sS https://gitlab.com/api/v4/user | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
echo "my access lvl:  $(curl -sS https://gitlab.com/api/v4/projects/$PID/members/all/$ME | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_level"))' 2>/dev/null) (20=Reporter 30=Dev 40=Maint)"
echo "-- write issue (create+delete) --"
IID=$(curl -sS -X POST "https://gitlab.com/api/v4/projects/$PID/issues" --data-urlencode 'title=[PROBE] delete me' --data 'issue_type=issue' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("iid",""))' 2>/dev/null)
DEL=$([ -n "$IID" ] && curl -sS -o /dev/null -w '%{http_code}' -X DELETE https://gitlab.com/api/v4/projects/$PID/issues/$IID)
echo "   issue create iid=${IID:-FAILED}  delete=$DEL"
echo "-- write wiki comment (create+destroy) --"
R=$(curl -sS -H 'Content-Type: application/json' -X POST --data '{"query":"mutation { createNote(input:{noteableId:\"gid://gitlab/WikiPage::Meta/6365911\", body:\"probe self-delete\"}){ note{ id } errors } }"}' https://gitlab.com/api/graphql)
echo "   raw: $(echo "$R" | head -c 200)"
NID=$(echo "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);n=(d.get("data") or {}).get("createNote") or {};print((n.get("note") or {}).get("id",""))' 2>/dev/null)
[ -n "$NID" ] && curl -sS -H 'Content-Type: application/json' -X POST --data "{\"query\":\"mutation { destroyNote(input:{id:\\\"$NID\\\"}){ errors } }\"}" https://gitlab.com/api/graphql >/dev/null && echo "   wiki note ok (destroyed)"
echo "-- existing SRS-001 notes (author) --"
curl -sS -H 'Content-Type: application/json' -X POST --data '{"query":"{ project(fullPath:\"protoswype-group/life-coach/ai-life-coach-business\"){ wikiPages(first:100){ nodes{ slug notes{ nodes{ author{username} body } } } } } }"}' https://gitlab.com/api/graphql | python3 -c 'import sys,json
d=json.load(sys.stdin)
for n in (d.get("data",{}).get("project",{}) or {}).get("wikiPages",{}).get("nodes",[]):
  for nt in (n["notes"]["nodes"] or []):
    if "srs" in n["slug"]: print("   ",n["slug"],"|",nt["author"]["username"],"|",nt["body"][:50].replace(chr(10)," "))' 2>/dev/null
