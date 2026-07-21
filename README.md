# NovaPay — AI-powered payments platform

> **This is a deliberately vulnerable demo repository.** It's the fictional
> customer "NovaPay" used to exercise **every Unveilr detection, asset type, and
> workflow** end to end. Do not copy this code — it is seeded with secrets, PII,
> insecure code, misconfigured IaC, risky dependencies, shadow MCP servers, and
> ungoverned AI agents on purpose.

NovaPay is a fintech that ships AI features fast: an autonomous **fraud-review
agent**, an AI **support agent**, LLM-assisted payment flows, and a React ops
dashboard. Like most teams shipping AI, it accumulated risk faster than security
could review it — which is exactly what Unveilr governs.

## What's in here (and what Unveilr finds)

| Path | AI-SDLC assets | Risks seeded |
|---|---|---|
| `agents/fraud_agent.py` | agent (CrewAI), model `claude-*` | hardcoded AWS key, PII, `eval`, weak hash |
| `agents/support_agent.py` | agent (LangChain), model `gpt-4o` | insecure TLS, `pickle` |
| `src/payments.py` | — | AWS/Stripe secrets, SSN + card (Luhn), `os.system`, `pickle` |
| `src/dashboard.jsx` | — | XSS (`dangerouslySetInnerHTML`), `eval`, TLS off |
| `infra/main.tf` | ai_service (Bedrock, SageMaker, Azure OpenAI) | public S3, open `0.0.0.0/0`, IAM `*`, `bedrock:*`, public RDS, unencrypted |
| `.cursor/mcp.json` | mcp_server ×4, ai_tool (cursor) | shadow / ungoverned MCP servers |
| `.env.example`, `Dockerfile`, `.github/workflows/ci.yml` | ai_key ×5 | exposed AI provider keys |
| `prompts/*.prompt.md` | prompt_file ×2 | — |
| `requirements.txt`, `package.json` | dependency | typosquat + hallucinated packages |

See **[UNVEILR_INTEGRATION.md](UNVEILR_INTEGRATION.md)** for the step-by-step
guide NovaPay's platform team follows to bring this under Unveilr's control plane.

## Run it against Unveilr

```bash
./demo.sh          # drives the full lifecycle: scan → govern → prove
```
