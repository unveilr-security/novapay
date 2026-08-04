# Testing Unveilr Guard on NovaPay — a walkthrough

An end-to-end evaluation against this repository, following the flow the
[documentation](https://docs.guard.unveilr.ai) describes: **Discover → Guard →
Govern → Contain → Prove.**

NovaPay is a deliberately vulnerable payments codebase. It has two CrewAI agents,
four MCP servers, hardcoded cloud and provider credentials, and PII in source. It
is a realistic estate to point a control plane at.

> **Every command and every output in this guide was run against this repo.**
> Numbers are what the tools actually printed, not illustrations. If your output
> differs, the repo or the version has changed — trust your output, not this page.

**Time:** about 30 minutes.

**You need:** the `unveilr` CLI for Part 1 (offline, no account required), and
from Part 2 onward an Unveilr tenant plus a service token from
**Settings → API Tokens**.

---

## Part 1 — Discover (offline, nothing to install server-side)

This is the part a prospect runs before trusting you with anything. It touches no
network and uploads nothing.

```bash
curl -fsSL https://get.unveilr.ai/install.sh | sh
cd /path/to/novapay
unveilr scan .
```

```
unveilr scan .: 36 assets, 39 findings (critical=3 high=27 medium=8 low=1)
```

### What is ungoverned, and what retires it

```bash
unveilr scan . --json | jq .shadow
```

```
discovered=36  shadow=13  governed=23  coverage=63.9%  registry=none

  Shadow agents             2   Register and approve an identity (owner, sponsor, purpose, tool scope).
  Shadow AI keys            3   Replace the standing key with a brokered, short-lived scoped credential.
  Shadow MCP servers        4   Register in the MCP registry and route calls through the gateway.
  Shadow AI services        2   Approve the provider endpoint and scope its IAM to least privilege.
  Shadow AI dependencies    2   Remove or pin the dependency to a verified package.
```

Every category names the action that retires it. A count with no action is a
scanner; the action is what makes it a control plane.

**`registry: none` matters.** Offline, Unveilr cannot know what your console has
registered, so it takes the honest posture of an ungoverned estate: every
discovered agent counts as unregistered, every standing key as unmediated. The
console's number will usually be *lower*. Both are correct about different
questions.

### A shareable readout

```bash
unveilr scan . --readout novapay-readout.html
# add --redact to replace file paths and asset names with stable hashes
```

Self-contained HTML, no external requests — safe to send to someone who will not
install anything.

### The CI gate

```bash
unveilr scan . --mode enforce --fail-on-shadow 0
```

```
unveilr scan .: 36 assets, 39 findings (…) FAIL(shadow 13>0)
exit=1
```

`--fail-on-shadow` is independent of `--fail-on`. They answer different
questions: *is anything here dangerous?* versus *is the AI here governed?* A repo
routinely passes one and fails the other. `N` is a ceiling, not a trigger — set
it to today's count to freeze the backlog, then lower it.

`--mode observe` (the default) never fails a build, whatever the flags say.

---

## Part 2 — Guard → Govern

Point the CLI and your shell at your Unveilr tenant. There is **one Admin API
origin**, and every authenticated call carries a bearer credential — see
[Authentication](https://docs.guard.unveilr.ai/api/authentication).

```bash
export UNVEILR_API=https://guard.unveilr.ai      # self-hosted: your own origin
export UNVEILR_TOKEN=uvt_…                       # Settings → API Tokens
```

The tenant comes from the credential, never from a header you send. Connect the
repository and scan it:

```bash
REPO=$(curl -fsS -X POST "$UNVEILR_API/v1/repos" \
  -H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json" \
  -d '{"provider":"local","name":"novapay","url":"/path/to/novapay","externalId":"np"}' \
  | jq -r .id)

curl -fsS -X POST "$UNVEILR_API/v1/repos/$REPO/scan" \
  -H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json" -d '{}'
```

To upload from CI instead, `unveilr login --token $UNVEILR_TOKEN` once, then
`unveilr scan . --upload`.

### Drill into a category

```bash
curl -fsS "$UNVEILR_API/v1/findings?shadowCategory=agent&status=open" \
  -H "Authorization: Bearer $UNVEILR_TOKEN"
```

```
Unregistered agent 'support_agent' — no identity, owner, or approval  agents/support_agent.py
Unregistered agent 'fraud_agent'  — no identity, owner, or approval  agents/fraud_agent.py
```

The rollup said "2 shadow agents"; the drill-down returns exactly those two. In
the console both counts on a Shadow AI row are links.

### Register an agent — and meet the deployment gate

```bash
AID=$(curl -fsS -X POST "$UNVEILR_API/v1/agent-identities" \
  -H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json" -d '{
  "name":"fraud_agent",
  "owner":"risk-eng@novapay.io",
  "sponsor":"ciso@novapay.io",
  "purpose":"review flagged transactions and recommend hold/release",
  "environment":"production",
  "allowedTools":["postgres-ledger.*"],
  "forbiddenTools":["stripe.*"],
  "dataScope":["financial"],
  "version":"1.4.0","versionPinned":true}' | jq -r .id)

curl -fsS -X POST "$UNVEILR_API/v1/agent-identities/$AID/approve" \
  -H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json"
```

```
activation blocked by Guard finding [critical/secret_leak] AWS access key id
(+7 more) — remediate or risk-accept (ignore) before retrying
```

**This is the point of the product.** The agent cannot be approved — and so
cannot mint a credential — while it has open critical findings. Discovery is not
a separate report; it gates deployment. `fraud_agent.py` has a hardcoded AWS key
on line 14, and that is what is blocking it.

Two ways forward, and both are decisions on record: remediate the finding, or
risk-accept it with a reason.

```bash
curl -fsS -X POST "$UNVEILR_API/v1/findings/$FINDING_ID/status" \
  -H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json" \
  -d '{"status":"ignored","reason":"demo estate — accepted for walkthrough"}'
```

Then approve again. Approval mints the agent's credential — the only one it gets.

### Govern real calls

Use the SDK, which is what your agents will use:

```bash
pip install unveilr
export UNVEILR_API=https://guard.unveilr.ai
export UNVEILR_AGENT_TOKEN=uvt_…        # shown once, at agent approval
export UNVEILR_AGENT_VERSION=1.4.0      # the version this agent is running
```

Note the two different credentials: `UNVEILR_TOKEN` is the **admin/service**
token you use for the calls above; `UNVEILR_AGENT_TOKEN` is the **agent's own**
credential, minted at approval and never shared with CI.

```python
import unveilr

for server, tool in [("postgres-ledger", "query"),
                     ("stripe", "create_refund"),
                     ("github", "delete_repo")]:
    d = unveilr.check(tool, {}, server=server,
                      initiator={"type": "human", "id": "entra:user:4471",
                                 "clientApplication": "fraud-console"})
    print(server, tool, d["decision"], d["reasonCodes"])
```

```
postgres-ledger.query    allow    []          within scope; no high-risk detections
stripe.create_refund     deny     ['SCOPE_DENIED']
github.delete_repo       deny     ['SCOPE_DENIED']
```

Every decision returns prose **and** machine-matchable
[reason codes](https://docs.guard.unveilr.ai/reason-codes). Prose is for the
person reading a denial at 03:00; codes are for your rules and dashboards.

`initiator` records **who the work is for**. Sessions are per initiator, so one
agent serving two people produces two attributable sessions rather than
attributing the second person's actions to the first.

### Standing credentials

The agent still holds the hardcoded AWS key. The SDK reports what it can resolve
— names and sources only, never values:

```
{'standing': True, 'sources': ['env:AWS_ACCESS_KEY_ID', 'env:AWS_SECRET_ACCESS_KEY'], 'providers': []}
```

Install a policy that refuses to authorize anything while it holds one:

```bash
curl -fsS -X POST "$UNVEILR_API/v1/policies" \
  -H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json" -d '{
  "name":"No standing credentials","priority":95,"effect":"deny",
  "match":{"toolNameGlobs":["*"],"ambientCredentials":true}}'
```

```
deny  ['AMBIENT_CREDENTIALS_HELD', 'POLICY_DENY']
  policy deny: matched "No standing credentials"; agent still holds ambient
  credentials (env:AWS_ACCESS_KEY_ID, env:AWS_SECRET_ACCESS_KEY); remove them
  and use brokered scoped credentials
```

The denial **names the variables to remove**. This is the enforcement half of
credential mediation: scoped tokens only shrink blast radius if they are the
agent's *only* authority.

> **Honest limit.** This is an *attestation* — the agent describes its own
> environment. It constrains an honest agent handed a key nobody removed, not one
> that lies. It is sealed as `verified: false`. The adversarial case is CloudTrail
> correlation: a call made with a credential the broker never issued.

### Version pinning

The agent was registered with `versionPinned: true`. Call it without reporting a
version:

```
deny  ['VERSION_DRIFT']
  agent is pinned to version 1.4.0 but is running unreported;
  re-approve the agent for this version or unpin it
```

Silence does not satisfy a pin. Only *pinned* agents are gated — denying every
patch release is how a control gets switched off.

---

## Part 3 — the flip to enforce

Everything so far ran in **Monitor Mode**: identical decisions, sealed
identically, blocking nothing. Note `[monitor] would deny` in the reasons above.

Before enforcing, ask what breaks:

```bash
curl -fsS $UNVEILR_API/v1/govern/readiness \
  -H "Authorization: Bearer $UNVEILR_TOKEN"
```

```
4 of 5 decisions would be blocked. 0 of 1 agent(s) ready; work the reasons below
before flipping.

FAIL  fraud_agent   4 would block of 5
      SCOPE_DENIED               2 → Add the tool to the agent's approved scope, or stop the agent calling it.
      AMBIENT_CREDENTIALS_HELD   1 → Remove the agent's standing credentials and let the broker issue scoped ones.
      POLICY_DENY                1 → Review the matching deny policy — it is doing what it was written to do.
      VERSION_DRIFT              1 → Re-approve the agent for the version it is running, or unpin it.
```

Grouped by **cause**, each with the action that closes it. Two `SCOPE_DENIED` on
one server is one scope edit; four different codes is four conversations.

Three things this report deliberately gets right:

- an agent with **no traffic** is `no_data`, never `ready` — silence is not safety;
- an **already-enforced** denial is not counted, because it is history, not a
  prediction of what the flip would cost;
- a **redaction** is not breakage: it transforms the call rather than refusing it.

### Enforce one agent, not the estate

```bash
curl -fsS -X PUT "$UNVEILR_API/v1/govern/enforcement" \
  -H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json" \
  -d '{"default":"observe","enforceAgents":["fraud_agent"]}'
```

```
enforced now: deny | allowed: False | enforced: True
```

The decision did not change. Only its consequence did — which is what makes the
monitor phase valid evidence for the enforce phase.

---

## Part 4 — Contain and Prove

### Stop an agent

```bash
curl -fsS -X POST "$UNVEILR_API/v1/sessions/agents/$AID/terminate" \
  -H "Authorization: Bearer $UNVEILR_TOKEN" -H "content-type: application/json" \
  -d '{"reason":"walkthrough containment"}'
```

```
sessions cut: 2
after containment: deny | session was terminated by an operator; issue a new credential
```

Termination is **sticky and credential-scoped**: a retry loop cannot undo it, and
neither can a different initiator. Containment also follows the delegation chain
— terminating a parent stops every sub-agent it delegated to, because otherwise
the authority it handed out keeps running.

### Verify the evidence

```bash
curl -fsS $UNVEILR_API/v1/evidence/verify \
  -H "Authorization: Bearer $UNVEILR_TOKEN"
```

```
chain ok=True  events=47  broken=0
```

Every decision above is in there, hash-chained. Open one to see the full sealed
record and check that single event's integrity without re-verifying the trail:

```bash
curl -fsS "$UNVEILR_API/v1/evidence/events/$EVENT_ID" \
  -H "Authorization: Bearer $UNVEILR_TOKEN"
```

### Compliance

```bash
curl -fsS $UNVEILR_API/v1/compliance/eu-ai-act \
  -H "Authorization: Bearer $UNVEILR_TOKEN"
```

Each control carries `drillDown` (the items behind the number), `drillDownApi`
(the same query as a request, so the pack is reproducible from a terminal), and
on a gap, `remediation`. A control is never reported satisfied by automation
alone — a named human attests, bound to a snapshot hash, and the attestation goes
stale if the evidence changes underneath it.

---

## What this walkthrough does not show

Stated so you do not discover them mid-evaluation:

- **Authority attenuation is not enforced yet.** A sub-agent's scope is not
  checked against its parent's. The delegation chain makes that expressible; the
  check is the next thing being built.
- **Attestations are attestations.** Initiator, agent version and ambient
  credentials are self-reported and sealed `verified: false`. Signed initiators
  (JWKS-validated actor claims) are verifiable; the rest are advisory.
- **No continuous evaluation.** Drift is detected for prompts and pinned
  versions; there is no behavioural baseline or cost-escalation detection yet.
- **Unveilr does not sandbox execution.** It governs the actions routed through
  it and removes the standing credentials that make ungoverned paths useful. It
  does not prevent an agent executing code on a machine you gave it.

---

## Reference

| Step | Docs |
|---|---|
| Install and scan | [Quickstart](https://docs.guard.unveilr.ai/quickstart) · [CLI reference](https://docs.guard.unveilr.ai/cli-reference) |
| Shadow AI | [Shadow AI](https://docs.guard.unveilr.ai/features/shadow-ai) |
| Agent identities | [Govern](https://docs.guard.unveilr.ai/features/govern) · [AgentScope](https://docs.guard.unveilr.ai/features/agentscope) |
| Initiator, version, sub-agents | [Delegation](https://docs.guard.unveilr.ai/features/delegation) |
| Standing credentials | [Ambient credentials](https://docs.guard.unveilr.ai/features/ambient-credentials) |
| Reason codes | [Reason codes](https://docs.guard.unveilr.ai/reason-codes) |
| Action tiers | [Action tiers](https://docs.guard.unveilr.ai/features/action-tiers) |
| Monitor → enforce | [Monitor Mode](https://docs.guard.unveilr.ai/features/monitor-mode) |
| Containment | [Sessions](https://docs.guard.unveilr.ai/features/sessions) |
| Evidence and packs | [Prove](https://docs.guard.unveilr.ai/features/prove) · [Compliance](https://docs.guard.unveilr.ai/features/compliance) |

The AWS credential-broker scenario — monitor → enforce on a real STS path — is in
[SCENARIO_BROKER_AWS.md](SCENARIO_BROKER_AWS.md).
