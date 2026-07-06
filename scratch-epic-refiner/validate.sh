PID=84091630
echo "who am I:"
curl -sS "https://gitlab.com/api/v4/user" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  username=",d.get("username"),"id=",d.get("id"),"name=",d.get("name"),"bot=",d.get("bot"))'
echo "token scopes:"
curl -sS "https://gitlab.com/api/v4/personal_access_tokens/self" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  scopes=",d.get("scopes"),"active=",d.get("active"),"expires=",d.get("expires_at"))' 2>/dev/null
echo "access level on project:"
curl -sS "https://gitlab.com/api/v4/projects/$PID/members/all?per_page=100" >/dev/null 2>&1
ME=$(curl -sS "https://gitlab.com/api/v4/user" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -sS "https://gitlab.com/api/v4/projects/$PID/members/all/$ME" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  access_level=",d.get("access_level"),"(30=Dev,40=Maintainer)")' 2>/dev/null
