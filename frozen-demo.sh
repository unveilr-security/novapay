#!/usr/bin/env bash
# NovaPay frozen partner demo — four beats only.
# Scan → Agents gate → Govern deny/allow → Evidence verify
#
#   export UNVEILR_TOKEN=uvt_… ./frozen-demo.sh
# Talk track: unveilr-guard/docs/DEMO_NOVAPAY.md
#
# Optional:
#   UNVEILR_APPROVE_TOKEN=uvt_…   # second admin when SOD blocks self-approve
#   AGENT_NAME=fraud_agent
set -euo pipefail

API="${UNVEILR_API:-https://guard.unveilr.ai}"
CONSOLE="${UNVEILR_CONSOLE:-https://guard.unveilr.ai}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_NAME="${AGENT_NAME:-fraud_agent}"
EXTERNAL_ID="${EXTERNAL_ID:-novapay-local}"

if [ -z "${UNVEILR_TOKEN:-}" ]; then
  echo "Set UNVEILR_TOKEN (mint at ${CONSOLE}/settings → API Tokens)." >&2
  exit 1
fi

H=(-H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json")
APPROVE_TOKEN="${UNVEILR_APPROVE_TOKEN:-$UNVEILR_TOKEN}"
HA=(-H "Authorization: Bearer $APPROVE_TOKEN" -H "content-type: application/json")

py() { python3 -c "$1" "${@:2}"; }
hr() { printf '\n\033[1;35m━━ %s\033[0m\n' "$1"; }
note() { printf '   %s\n' "$1"; }
die() { printf '\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# Read JSON from stdin; print field value or exit 2 with a useful stderr dump.
json_get() {
  local field="$1"
  py "
import sys, json
raw = sys.stdin.read()
try:
    d = json.loads(raw) if raw.strip() else {}
except Exception as e:
    print('non-JSON response:', repr(raw[:500]), file=sys.stderr)
    raise SystemExit(2) from e
if isinstance(d, dict) and d.get('$field') not in (None, ''):
    print(d['$field'])
    raise SystemExit(0)
print(\"API response missing '$field':\", d.get('detail', d) if isinstance(d, dict) else d, file=sys.stderr)
print('body=', repr(raw[:800]), file=sys.stderr)
raise SystemExit(2)
"
}

# HTTP helper: body on stdout, status code on fd3 via global LAST_HTTP
http_json() {
  local tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' "$@")"
  LAST_HTTP="$code"
  cat "$tmp"
  rm -f "$tmp"
}

curl -sf "$API/healthz" >/dev/null || die "Platform not reachable at $API/healthz"
curl -sf "${H[@]}" "$API/v1/onboarding" >/dev/null 2>&1 || \
  die "Auth failed against $API/v1/onboarding — check UNVEILR_TOKEN (mint at $CONSOLE/settings)."

hr "1 · SCAN — novapay/platform ($REPO_DIR)"
REPO_JSON="$(http_json "${H[@]}" -XPOST "$API/v1/repos" \
  -d "{\"provider\":\"local\",\"name\":\"novapay/platform\",\"url\":\"$REPO_DIR\",\"externalId\":\"$EXTERNAL_ID\",\"defaultBranch\":\"main\"}")"
if ! RID="$(printf '%s' "$REPO_JSON" | json_get id)"; then
  note "create returned HTTP ${LAST_HTTP:-?} — looking up existing repo…"
  RID="$(curl -sS "${H[@]}" "$API/v1/repos" | py "
import sys, json
items = json.load(sys.stdin)
if isinstance(items, dict):
    items = items.get('items') or items.get('repos') or []
ext, name = sys.argv[1], sys.argv[2]
for r in items:
    if r.get('externalId') == ext or r.get('name') == name:
        print(r['id']); raise SystemExit(0)
print('no matching repo; create body was missing id', file=sys.stderr)
raise SystemExit(2)
" "$EXTERNAL_ID" "novapay/platform")" || die "Could not create or find novapay/platform (create HTTP ${LAST_HTTP:-?}). Body: $REPO_JSON"
fi
note "repo $RID  ·  $CONSOLE/repos/$RID"

if command -v unveilr >/dev/null 2>&1; then
  note "uploading via CLI (attaches source for Evidence)…"
  (
    cd "$REPO_DIR"
    export UNVEILR_API="$API"
    unveilr login --token "$UNVEILR_TOKEN" --api "$API" >/dev/null
    unveilr scan --upload
  ) || note "CLI upload reported an error — continuing with whatever findings exist"
else
  note "unveilr CLI not on PATH — trying API scan (often fails for provider=local on hosted API)"
  SCAN_JSON="$(http_json "${H[@]}" -XPOST "$API/v1/repos/$RID/scan" -d '{"source":"api"}')"
  printf '%s' "$SCAN_JSON" | py "
import sys, json
d = json.load(sys.stdin)
print('   scan', d.get('status', d.get('detail', '?')), d.get('stats', {}))
if d.get('detail') and not d.get('status'):
    print('   hint: install CLI + unveilr scan --upload — hosted API cannot read laptop paths')
"
fi

curl -sS "${H[@]}" "$API/v1/findings?repoId=$RID&limit=200" | py "
import sys, json
items = json.load(sys.stdin).get('items', [])
print(f'   {len(items)} findings  ·  $CONSOLE/findings')
for f in sorted(items, key=lambda x: -x.get('riskScore', 0))[:3]:
    print(f\"     [{f.get('riskScore', 0):3}] {f.get('severity', '?'):8} {f.get('title', '')[:56]}\")
"

hr "2 · AGENTS GATE — register + approve $AGENT_NAME"
REG_JSON="$(http_json "${H[@]}" -XPOST "$API/v1/agent-identities" \
  -d "{\"name\":\"$AGENT_NAME\",\"owner\":\"risk-eng@novapay.example\",\"allowedTools\":[\"ledger.query\",\"github.get_file\"]}")"
if ! AID="$(printf '%s' "$REG_JSON" | json_get id)"; then
  note "register HTTP ${LAST_HTTP:-?} — looking up existing agent…"
  AID="$(curl -sS "${H[@]}" "$API/v1/agent-identities" | py "
import sys, json
items = json.load(sys.stdin)
if isinstance(items, dict):
    items = items.get('items') or []
name = sys.argv[1]
for a in items:
    if a.get('name') == name:
        print(a['id']); raise SystemExit(0)
print('agent not found in list', file=sys.stderr)
raise SystemExit(2)
" "$AGENT_NAME")" || die "Could not register or find $AGENT_NAME (HTTP ${LAST_HTTP:-?}). Body: $REG_JSON"
  note "using existing agent $AID"
  STATE="$(curl -sS "${H[@]}" "$API/v1/agent-identities/$AID" | py "
import sys, json
d = json.load(sys.stdin)
print(d.get('approvalState') or d.get('approval_state') or '')
")"
  if [ "$STATE" = "approved" ]; then
    note "revoking prior credential so approve can remint…"
    http_json "${HA[@]}" -XPOST "$API/v1/agent-identities/$AID/revoke" >/dev/null
  fi
else
  note "registered $AID"
fi

AP_JSON="$(http_json "${HA[@]}" -XPOST "$API/v1/agent-identities/$AID/approve")"
if ! TOKEN="$(printf '%s' "$AP_JSON" | json_get token)"; then
  DETAIL="$(printf '%s' "$AP_JSON" | py "import sys,json;d=json.load(sys.stdin);print(d.get('detail', d))" 2>/dev/null || printf '%s' "$AP_JSON")"
  if printf '%s' "$DETAIL" | grep -qi "separation of duties"; then
    die "SoD blocked approve (HTTP ${LAST_HTTP:-?}). Mint a second admin token and re-run:
  export UNVEILR_APPROVE_TOKEN=uvt_…_other_admin
  $0"
  fi
  die "Approve failed (HTTP ${LAST_HTTP:-?}): $DETAIL"
fi
printf '%s' "$AP_JSON" | py "
import sys, json
d = json.load(sys.stdin)
ident = d.get('identity') or {}
print('   approved', ident.get('name'))
print('   tools', ident.get('allowedTools') or ident.get('allowed_tools'))
print('   token', (d.get('token') or '')[:18] + '…')
"
note "console $CONSOLE/agents"

hr "3 · GOVERN — AI-on-AI chain deny, then allow (Path A)"
AH=(-H "Authorization: Bearer $TOKEN" -H "content-type: application/json")
gov() {
  local label="$1" body="$2"
  curl -sS "${AH[@]}" -XPOST "$API/v1/govern/check" -d "$body" | py "
import sys, json
d = json.load(sys.stdin)
if 'decision' not in d:
    print(f\"   {sys.argv[1]:18} → ERROR {d.get('detail', d)!r}\", file=sys.stderr)
    raise SystemExit(2)
rs = d.get('ruleSetHash') or ''
print(f\"   {sys.argv[1]:18} → {str(d.get('decision', '?')).upper():5}  reason={str(d.get('reason', ''))[:48]}\")
print(f\"          ruleSetHash={rs[:16]}…  bundle={d.get('policyBundleVersion')}  evidenceId={d.get('evidenceId')}\")
" "$label"
}
gov "1 credential"   '{"server":"secrets","tool":"get","arguments":{"path":".env"}}'
gov "2 priv-esc"     '{"server":"iam","tool":"assume_role","arguments":{"role":"admin"}}'
gov "3 host/RCE"     '{"server":"shell","tool":"exec","arguments":{"cmd":"id"}}'
gov "4 destructive"  '{"server":"ledger","tool":"drop_table","arguments":{}}'
gov "5 in-scope"     '{"server":"ledger","tool":"query","arguments":{"sql":"select count(*) from txns"}}'

hr "4 · EVIDENCE — verify chain (Act III)"
curl -sS "${H[@]}" "$API/v1/evidence/verify" | py "
import sys, json
d = json.load(sys.stdin)
print(f\"   ok={d.get('ok')}  checked={d.get('checked')}  tampered={len(d.get('tampered') or [])}\")
"
note "console $CONSOLE/evidence — open denials; point at ruleSetHash"

hr "DONE — frozen path complete"
note "Platform: $API"
note "Talk track: unveilr-guard/docs/DEMO_NOVAPAY.md (AI-on-AI Beat 3–4)"
note "Trust copy: unveilr-guard/docs/TRUST.md § AI-on-AI incidents"
