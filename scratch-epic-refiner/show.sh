curl -sS -H 'Content-Type: application/json' -X POST --data '{"query":"{ project(fullPath:\"protoswype-group/life-coach/ai-life-coach-business\"){ wikiPages(first:100){ nodes{ slug notes{ nodes{ author{username} createdAt body } } } } } }"}' https://gitlab.com/api/graphql | python3 -c '
import sys,json
for n in json.load(sys.stdin)["data"]["project"]["wikiPages"]["nodes"]:
  if n["slug"].endswith("SRS-001-data-ingestion"):
    for nt in (n["notes"]["nodes"] or []):
      print("AUTHOR:",nt["author"]["username"],"AT:",nt["createdAt"]); print(nt["body"]); print("----")'
