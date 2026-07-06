PID=84091630
h(){ curl -sS -o /dev/null -w "%{http_code}" "$@"; }
echo "READ project:        $(h https://gitlab.com/api/v4/projects/$PID)"
echo "READ wikis+content:  $(h "https://gitlab.com/api/v4/projects/$PID/wikis?with_content=true")"
echo "READ issues:         $(h "https://gitlab.com/api/v4/projects/$PID/issues?per_page=1")"
echo "WRITE issue (POST):  $(h -X POST "https://gitlab.com/api/v4/projects/$PID/issues" --data-urlencode 'title=[PROBE] x' --data 'issue_type=issue')"
echo "-- wiki notes readable? (count) --"
curl -sS -H 'Content-Type: application/json' -X POST --data '{"query":"{ project(fullPath:\"protoswype-group/life-coach/ai-life-coach-business\"){ wikiPages(first:100){ nodes{ slug notes{ nodes{ id } } } } } }"}' https://gitlab.com/api/graphql | python3 -c 'import sys,json
d=json.load(sys.stdin)
if "errors" in d: print("  gql err:",d["errors"][0]["message"][:80]); 
else:
  for n in d["data"]["project"]["wikiPages"]["nodes"]:
    c=len(n["notes"]["nodes"] or [])
    if "srs" in n["slug"]: print("  ",n["slug"],"notes=",c)'
echo "-- parent group id (for member-add) --"
curl -sS "https://gitlab.com/api/v4/projects/$PID" | python3 -c 'import sys,json;d=json.load(sys.stdin);ns=d["namespace"];print("  group full_path=",ns["full_path"],"id=",ns["id"],"kind=",ns["kind"])' 2>/dev/null
