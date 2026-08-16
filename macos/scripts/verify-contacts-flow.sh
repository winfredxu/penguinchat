#!/usr/bin/env bash
# Two-user acceptance for the native contacts stage (WINL-10).
# Exercises the same REST contract the macOS ContactsStore calls.
set -euo pipefail

API="${PENGUINCHAT_API_URL:-http://127.0.0.1:3100}"
SUFFIX="$(date +%s)"
A="alice_$SUFFIX"
B="bob_$SUFFIX"
PASS="penguin-secret-1"

json() { python3 -c "import json,sys;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1"; }

register() {
  curl -sS -X POST "$API/auth/register" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"display_name\":\"$2\",\"password\":\"$PASS\"}"
}

echo "== register two users on $API =="
TOKEN_A="$(register "$A" "Alice" | json "['tokens']['accessToken']")"
TOKEN_B="$(register "$B" "Bob" | json "['tokens']['accessToken']")"

echo "== $A sends a friend request to $B =="
REQ="$(curl -sS -X POST "$API/friend-requests" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$B\",\"message\":\"hi from the native client\"}")"
echo "$REQ"

echo "== $B lists incoming requests =="
INCOMING="$(curl -sS "$API/friend-requests" -H "Authorization: Bearer $TOKEN_B")"
echo "$INCOMING"
REQ_ID="$(printf '%s' "$INCOMING" | json "[0]['id']")"

echo "== $B accepts request $REQ_ID =="
curl -sS -X POST "$API/friend-requests/$REQ_ID/accept" -H "Authorization: Bearer $TOKEN_B"
echo

echo "== both rosters after accept =="
CONTACTS_A="$(curl -sS "$API/contacts" -H "Authorization: Bearer $TOKEN_A")"
CONTACTS_B="$(curl -sS "$API/contacts" -H "Authorization: Bearer $TOKEN_B")"
echo "A: $CONTACTS_A"
echo "B: $CONTACTS_B"

python3 - "$CONTACTS_A" "$CONTACTS_B" "$A" "$B" <<'PY'
import json, sys
a, b, name_a, name_b = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3], sys.argv[4]
assert [c["username"] for c in a] == [name_b], a
assert [c["username"] for c in b] == [name_a], b
assert all("presence" in c for c in a + b), "presence missing from contact snapshot"
print("PASS: mutual single-row roster with presence:", a[0]["presence"], b[0]["presence"])
PY

echo "== incoming requests cleared for $B =="
curl -sS "$API/friend-requests" -H "Authorization: Bearer $TOKEN_B"
echo
