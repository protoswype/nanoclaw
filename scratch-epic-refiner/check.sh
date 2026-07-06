curl -sS -H 'Content-Type: application/json' -X POST --data '{"query":"{ project(fullPath:\"protoswype-group/life-coach/ai-life-coach-business\"){ wikiPages(first:100){ nodes{ slug notes{ nodes{ author{username} createdAt body } } } } } }"}' https://gitlab.com/api/graphql | python3 -c 'import sys,json
for n in json.load(sys.stdin)["data"]["project"]["wikiPages"]["nodes"]:
  for nt in (n["notes"]["nodes"] or []):
    if "srs" in n["slug"]: print("  ",n["slug"],"|",nt["author"]["username"],"|",repr(nt["body"][:70]))'
