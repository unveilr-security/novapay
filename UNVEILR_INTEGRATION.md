# Integrating Unveilr — a guide for the NovaPay platform team

This is the guide NovaPay's platform/security team follows to bring the estate
under Unveilr's AI-SDLC control plane. It's written from the customer's side of
the screen. Every command here runs against this repo and is exercised end to
end by [`demo.sh`](demo.sh).

**The mental model:** *Discover → Guard → Govern → Prove.* You inventory the AI
you have, catch risk before it ships, govern what agents do at runtime, and
produce tamper-evident proof — with a human attesting each compliance control.

---

## 0. Prerequisites

- The Unveilr **Admin API** reachable (self-hosted or SaaS). Locally:
  `uvicorn unveilr_api.main:app --port 8080`. Set `API=https://unveilr.novapay.example`.
- The **console** for humans: `http://localhost:3000` (or your hosted URL).
- The **CLI** for developers and CI: `curl -fsSL https://get.unveilr.dev/install.sh | sh`.
- Auth: in production every request carries a WorkOS SSO token or a service
  token (`uvt_…`). In local dev the console/API accept dev headers
  (`X-Unveilr-Tenant`, `X-Unveilr-User`, `X-Unveilr-Roles`). Examples below use
  dev headers; swap in `Authorization: Bearer <token>` for real deployments.

```bash
export API=http://localhost:8080
H=(-H "X-Unveilr-Tenant: ten_novapay" -H "X-Unveilr-User: platform@novapay" -H "X-Unveilr-Roles: admin" -H "content-type: application/json")
```

---

## 1. Discover — inventory every AI in the estate

### From the developer's terminal (no upload)
```bash
cd novapay
unveilr scan               # deterministic, offline; prints the AI-BOM + findings
```

### Bring a repo under the control plane
```bash
RID=$(curl -s "${H[@]}" -XPOST "$API/v1/repos" \
  -d '{"provider":"local","name":"novapay/platform","url":"'"$PWD"'","externalId":"novapay"}' \
  | jq -r .id)
curl -s "${H[@]}" -XPOST "$API/v1/repos/$RID/scan" -d '{}'
```
For a GitHub repo, connect the **GitHub App** instead (Settings → Connect
GitHub) — Unveilr then scans every PR automatically.

### What you get
- **Per-repo AI-BOM** — `GET /v1/repos/$RID/aibom`: agents, models, prompts, MCP
  servers, AI keys, AI services, dependencies, coding tools.
- **Org-wide Shadow-AI rollup** — `GET /v1/aibom`: *"N AI tools · M MCP servers ·
  K agents…"* plus provider usage and the count of **ungoverned** MCP servers.
- **CycloneDX ML-BOM export** — `GET /v1/repos/$RID/aibom/cyclonedx` for your SBOM
  tooling and auditors.

On this repo you'll see 8 asset kinds and ~35 assets discovered, including the
`fraud_agent` and `support_agent`, four MCP servers (all *shadow*, because they're
declared in `.cursor/mcp.json` with no central approval), and five exposed AI keys.

---

## 2. Guard — catch risk before it ships

### In the IDE
Install the **VS Code extension**; it runs `unveilr scan` on save and shows
findings in the Problems panel.

### In CI / the PR (the gate developers feel)
Add the GitHub Action, or call the CLI directly:
```bash
unveilr scan --diff pr.diff --mode enforce --fail-on high --sarif results.sarif
```
- `--diff` judges a PR on **the risk it introduces**, not pre-existing issues.
- `--mode enforce` fails the build at/above `--fail-on`; `--mode observe`
  (**Monitor Mode**) reports without ever failing — roll out safely, watch it be
  right, then enforce.
- `--sarif` renders findings as **native GitHub code-scanning annotations**, each
  tagged with its **OWASP LLM Top 10 / MITRE ATLAS** reference.

Every detection is deterministic and offline — same result in the editor, CI, and
server-side. See what fires: secrets, PII (incl. Luhn-valid cards), insecure code
(`eval`, XSS, TLS-off, `pickle`, shell), IaC misconfig, over-broad AI IAM,
typosquatted/hallucinated dependencies, shadow MCP, and unregistered agents.

### Findings, ranked by blast radius
`GET /v1/findings?repoId=$RID` returns findings scored 0–100 and tagged
`low|medium|high` blast radius — a secret in a repo that also ships a public
bucket with a `bedrock:*` role outranks the same secret in an internal repo.
Triage from the console or `POST /v1/findings/{id}/status`.

---

## 3. Govern — control what agents actually do

### The agent deployment gate
Discovered agents start **unregistered**. An unregistered agent cannot mint a
gateway credential, so its tool calls fail closed. To ship one:

```bash
# register with a NAMED OWNER (required) and a least-privilege tool scope
AID=$(curl -s "${H[@]}" -XPOST "$API/v1/agent-identities" \
  -d '{"name":"fraud_agent","owner":"risk-eng@novapay.example","allowedTools":["postgres-ledger.query","github.get_file"]}' \
  | jq -r .id)

# approval MINTS the credential (shown once) and resolves the gate finding
curl -s "${H[@]}" -XPOST "$API/v1/agent-identities/$AID/approve"
```
- **Approval is the gate:** no approval → no credential → the agent can't act.
- **`allowedTools` is enforced per call** at the gateway, in every mode. A call
  outside the scope is denied with a hash-chained block event.
- **Revoke** (`/revoke`) kills the credential instantly — a per-agent kill switch.
- Manage all of this on the console **Agents** page (register, approve, edit
  scope, revoke).

### Route agent traffic through the gateway
Point your MCP client at the gateway instead of the raw server:
`POST /mcp/{tenant}/{serverId}` with the agent's `uvt_` credential. The gateway
runs the full pipeline on every call: approval → schema validation → rug-pull
quarantine → rate-limit → **agent scope** → request detection → policy
(allow/deny/approve/step-up/redact/sanitize) → forward → response scan → anomaly
→ audit.

### Correlate authoring to runtime
```bash
curl -s "${H[@]}" -XPOST "$API/v1/correlation/runtime"
```
Matches MCP servers **declared in code** to servers **known to the gateway**. A
declared server matched to an approved registry entry resolves its `shadow_mcp`
finding automatically; matched to an ungoverned one, it amplifies blast radius —
the code surface is live, not theoretical.

---

## 4. Remediate — close findings, tracked to proof

From the console **Remediation** hub (or the API), each finding shows its
recommended fix and a one-click action:
```bash
curl -s "${H[@]}" -XPOST "$API/v1/remediation/findings/$FID" -d '{"action":"pr"}'
```
- **GitHub-connected repo** → a **fix PR** (never auto-merged — a proposal to review).
- **Local repo** → a **unified-diff patch** you download and `git apply`.
- Deterministic and safe only: remove a hallucinated dep, rename a typosquat,
  replace a hardcoded secret with an env reference (**and** rotate it).

### Hand risk to your tracker
Configure **Jira** or **ServiceNow** once (Settings → Integrations), then open a
ticket from any finding — the ticket links back and the finding moves to triaged.

### Alert your team
Configure a **Slack / webhook** channel (Settings → Notifications); a completed
scan fans high-risk findings to it.

---

## 5. Prove — evidence and attested compliance

### Tamper-evident evidence
Every decision — scan, approval, correlation, remediation, gateway block — is
sealed into a **hash-chained ledger**. Verify integrity any time:
```bash
curl -s "${H[@]}" "$API/v1/evidence/verify"     # {"ok":true,"tampered":[]}
```

### Compliance: evidence + human attestation
Unveilr maps your posture to **11 frameworks** (NIST AI RMF · EU AI Act · SOC 2 ·
OWASP Agentic SAMM · ISO 42001 · NIST SSDF/218A · DORA · NIS2 · HIPAA · PCI DSS ·
ISO 27001). Critically, **automated signals establish *evidence* only — they never
mark a control satisfied on their own.** A named human (admin / auditor /
compliance / security role) must attest each control against the evidence:

```bash
curl -s "${H[@]}" "$API/v1/compliance/eu-ai-act"    # evidenceCoveragePct + attestedPct per control

# a compliance officer attests a control against the reviewed evidence
curl -s "${H[@]}" -XPOST "$API/v1/compliance/eu-ai-act/controls/Art.%2012/attestations" \
  -d '{"status":"confirmed","statement":"Reviewed the hash-chained evidence ledger for Q3; record-keeping operates as intended.","evidenceRefs":["https://console.novapay.example/evidence"]}'
```
Attestations are **append-only** and bound to the **evidence hash** at the moment
of signing — if the underlying evidence later changes, the attestation is flagged
**stale**, so a report can never silently drift out of date.

---

## 6. Ingest your existing scanners

Keep Snyk / Semgrep / CodeQL / garak — Unveilr **ingests** them so their findings
join the same blast-radius, evidence, and compliance model:
```bash
semgrep --sarif --output pr.sarif .
curl -s "${H[@]}" -XPOST "$API/v1/repos/$RID/ingest?source=sarif" --data-binary @pr.sarif
```

---

## 7. Roll-out plan for NovaPay

1. **Week 1 — Discover.** Connect all repos; review the org AI-BOM and the shadow
   MCP list. No enforcement yet.
2. **Week 2 — Guard in Monitor Mode.** Turn on PR checks in `observe`; watch the
   findings, tune `--fail-on`. Ingest existing scanners.
3. **Week 3 — Guard enforced + Remediate.** Flip high-severity to `enforce`; wire
   Jira; start closing findings via fix PRs/patches.
4. **Week 4 — Govern.** Register and approve agents with least-privilege scopes;
   route the fraud + support agents through the gateway; run the correlation join.
5. **Ongoing — Prove.** Compliance officer attests controls quarterly against the
   evidence ledger; export CycloneDX and evidence for auditors.

---

## The whole thing, end to end

```bash
./demo.sh      # runs steps 1–5 against a running Admin API and prints the story
```

Questions → your Unveilr solutions contact, or the docs at
`http://localhost:3001` (self-hosted docs site).
