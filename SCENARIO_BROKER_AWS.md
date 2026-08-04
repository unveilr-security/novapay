# Scenario — one high-blast-radius path, monitor → enforce

> **The wedge.** Not the whole estate — *one* action, made real. NovaPay's fraud
> agent must read a flagged transaction (card + PII) from S3. Today it would use a
> standing admin key (`AKIA…`, `s3:*` — see `agents/fraud_agent.py` and
> `infra/main.tf`). We put that single action under Unveilr and prove the loop:
>
> **Discover** the AI-BOM → **show** the identity graph + agent risk → **flip one
> control to enforce**: scoped-token brokerage on the privileged AWS action —
> deny the standing key, issue an STS-scoped credential, CloudTrail-correlate it
> to `bounded_authority_proven`, sealed in tamper-evident evidence.
>
> This is a **design-partner pilot script**. It runs against **real AWS** (a small,
> safe, least-privilege footprint) and a running Unveilr Admin API. Target: get
> this one path from *discovered* to *enforced-and-proven* — that's your first E3.

Companion to [`UNVEILR_INTEGRATION.md`](UNVEILR_INTEGRATION.md) (the full
Discover→Guard→Govern→Prove tour). This doc is the deep, runnable slice for the
credential-mediation control specifically.

---

## 0. Prerequisites

- **Real AWS**: an account with `aws` CLI authenticated, permission to create one
  S3 bucket + one IAM role (+ optionally a CloudTrail). Footprint is pennies;
  CloudTrail data events are opt-in and billed per event.
- **Unveilr Admin API** reachable, run with **broker settings** and AWS creds in
  its environment (so it can `sts:AssumeRole` and `cloudtrail:LookupEvents`).
- `jq` for the snippets.

```bash
export API=http://localhost:8080
H=(-H "X-Unveilr-Tenant: ten_novapay" -H "X-Unveilr-User: platform@novapay" \
   -H "X-Unveilr-Roles: admin" -H "content-type: application/json")
pip install -r demo/requirements.txt
```

---

## 1. Provision the real AWS path (least-privilege, safe)

`infra/main.tf` is deliberately poisoned ("do not apply"). Use the dedicated
provisioner instead — it creates a **private** bucket, the flagged object, an
out-of-scope **decoy** (to prove the boundary), and the role the broker assumes:

```bash
cd infra/broker-demo
./provision.sh up --region us-east-1            # add --with-cloudtrail for data-event correlation
# copy the `export …` block it prints:
#   BROKER_ROLE_ARN, AWS_REGION, CLOUDTRAIL_ENABLED,
#   BROKER_BUCKET, BROKER_OBJECT_KEY, BROKER_DECOY_KEY
cd ../..
```

The role permits the **superset** (`s3:GetObject` on `flagged/*`); the broker's
per-request **session policy** narrows each issued credential to the single object.
That intersection is what makes the decoy read fail.

---

## 2. Run the Unveilr API with broker settings

The API process needs the broker role ARN and AWS credentials (to assume it):

```bash
eval "$(aws configure export-credentials --format env)"   # put AWS creds in the API env
export BROKER_ENABLED=true                                 # arm the credential broker
export BROKER_ROLE_ARN=arn:aws:iam::<acct>:role/novapay-broker-target
export CLOUDTRAIL_ENABLED=true        # false is fine — AssumeRole still correlates on mgmt events
export AWS_REGION=us-east-1
ALLOW_DEV_HEADERS=true uvicorn unveilr_api.main:app --port 8080
```

> Without `BROKER_ENABLED=true` + `BROKER_ROLE_ARN`, the PDP still returns
> `scoped_token` but issuance fails with *"credential broker is not enabled"* —
> useful for a dry run of the decision path, but no real credential is minted.

---

## 3. Discover — inventory the AI, surface the standing key

```bash
RID=$(curl -s "${H[@]}" -XPOST "$API/v1/repos" \
  -d '{"provider":"local","name":"novapay/platform","url":"'"$PWD"'","externalId":"novapay"}' | jq -r .id)
curl -s "${H[@]}" -XPOST "$API/v1/repos/$RID/scan" -d '{}' >/dev/null

curl -s "${H[@]}" "$API/v1/repos/$RID/aibom" | jq '{agents, keys: (.aiKeys|length)}'
# → fraud_agent + support_agent discovered; the hardcoded AWS standing key is a finding.
```

---

## 4. Show the identity graph + agent risk

```bash
curl -s "${H[@]}" "$API/v1/identity/graph" \
  | jq '.nodes[] | select(.type=="agent") | {name, riskTier: .meta.riskTier, score: .meta.riskScore}'
# → fraud_agent, with a deterministic risk tier/score (prod access + sensitive data + standing cred).
```

Open the console **Identity** page to see it drawn: `owner → agent → credential →
resource`, the stripe coloured by real risk. This is the "who/what has reach"
picture that makes the next step legible to a CISO.

---

## 5. Register the agent, scope it, and set the control to `scoped_token`

Register with a **named owner + sponsor + purpose** (production approval requires
all three) and a least-privilege tool scope that includes the AWS read:

The tool scope grammar is **`server.tool`** (case-insensitive: `*` · `tool` ·
`server.*` · `server.tool`). Because the tool name `aws.s3.GetObject` itself
contains dots, it must be **server-qualified** — `aws-prod.aws.s3.GetObject` — or
the call is denied at the scope gate before policy ever runs. An empty scope
allows nothing (fail closed).

```bash
AID=$(curl -s "${H[@]}" -XPOST "$API/v1/agent-identities" -d '{
  "name":"fraud_agent","owner":"risk-eng@novapay.example","sponsor":"ciso@novapay.example",
  "environment":"production","purpose":"Review flagged transactions and decide hold/release/escalate",
  "allowedTools":["aws-prod.aws.s3.GetObject","postgres-ledger.query"]
}' | jq -r .id)

# approval MINTS the agent credential (shown once)
export UNVEILR_AGENT_TOKEN=$(curl -s "${H[@]}" -XPOST "$API/v1/agent-identities/$AID/approve" | jq -r '.token')

# the one control: privileged AWS actions get brokered, scoped creds — never standing keys
curl -s "${H[@]}" -XPOST "$API/v1/policies" -d '{
  "name":"Broker scoped creds for privileged AWS actions",
  "priority":100, "effect":"scoped_token",
  "match":{"toolNameGlobs":["aws.*"]}
}' >/dev/null
```

Export the values from step 1 so the harness can reach S3:

```bash
export UNVEILR_API=$API
export BROKER_BUCKET=novapay-broker-demo-<acct>
export BROKER_OBJECT_KEY=flagged/txn-88431.json
export BROKER_DECOY_KEY=flagged/txn-99999.json
export AWS_REGION=us-east-1
```

---

## 6. Monitor — watch the control be right, enforce nothing

```bash
python demo/broker_enforce.py --mode monitor
```
Prints the decision Unveilr **would** take (`scoped_token`) and seals it as
evidence — but the agent is **not** blocked and no credential is minted. This is
the safe rollout: prove the control fires correctly on the real path first.

---

## 7. Enforce — deny the standing key, prove bounded authority

```bash
python demo/broker_enforce.py --mode enforce
```
What happens, in order:
1. **Standing key denied.** The PDP returns `scoped_token` (`allowed=false` for the
   raw call) — the agent may **not** proceed with `AKIA…`.
2. **Scoped credential issued.** The broker `sts:AssumeRole`s the target role with
   an inline session policy = `s3:GetObject` on **this one object**. Short-lived
   `ASIA…`; the secret is returned to the caller and **never sealed**.
3. **In-scope read succeeds** with the scoped credential — the flagged txn.
4. **Out-of-scope decoy read is DENIED** (`AccessDenied`) — the boundary held.
5. **CloudTrail correlation** → `bounded_authority_proven` (in-scope success +
   out-of-scope denial, matched back to the grant by access-key id).

Every step chains into the evidence ledger (`credential.issued.v1`,
`credential.activity.v1`, the `policy_decision`).

---

## 8. Prove — tamper-evident evidence

```bash
curl -s "${H[@]}" "$API/v1/evidence/verify" | jq                 # {"ok":true,"tampered":[]}
curl -s "${H[@]}" "$API/v1/broker/credentials" | jq '.[0] | {credentialId, action, resource, status}'
```
The credential's issuance, its scoped grant, its real CloudTrail activity, and the
bounded-authority verdict are one hash-chained story — the proof a design partner
(and their auditor) can pull on demand.

---

## 9. Teardown

```bash
cd infra/broker-demo && ./provision.sh down --region us-east-1
# in Unveilr: revoke the agent credential (per-agent kill switch)
curl -s "${H[@]}" -XPOST "$API/v1/agent-identities/$AID/revoke" >/dev/null
```

---

## What "E3 on this path" means (pilot exit)

One real agent · one real privileged AWS action · enforced (scoped, not standing) ·
CloudTrail-proven `bounded_authority_proven` · sealed in evidence the platform
owner can pull — with the monitor→enforce transition done in the partner's own
runtime. That single proven path is the reference story that unlocks the rest.

## Notes & honesty

- **AssumeRole always correlates** on default management events. The **decoy-denial**
  and **in-scope GetObject** are S3 **data** events — they need `--with-cloudtrail`
  (or an existing org data-event trail) and take ~5–15 min to appear; re-run the
  correlate step or step 7 if the first verdict is `no_activity`.
- The broker uses a **single** `BROKER_ROLE_ARN` from API settings (not per-request).
  Multi-account / per-resource role selection is a follow-up, not wired here.
- Nothing in this repo provisions AWS on its own. `provision.sh` runs only when
  **you** run it, with **your** credentials.
