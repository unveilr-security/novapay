"""NovaPay autonomous fraud-review agent.

Reviews flagged transactions and decides hold / release / escalate. Built with
CrewAI; calls Claude for reasoning and a set of MCP tools for data access.

⚠️ Seeded with vulnerabilities for the Unveilr demo — do not deploy.
"""
import hashlib
import os

from crewai import Agent, Crew, Task

# --- SECRET LEAK: hardcoded cloud + provider credentials -------------------
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
AWS_SECRET_ACCESS_KEY = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
ANTHROPIC_API_KEY = os.environ["ANTHROPIC_API_KEY"]

# --- PII: a hardcoded reviewer record --------------------------------------
ESCALATION_CONTACT = {
    "name": "Dana Ruiz",
    "email": "dana.ruiz@novapay.example",
    "ssn": "512-84-2301",
}

FRAUD_MODEL = "claude-3-5-sonnet-20241022"


def _fingerprint(card_number: str) -> str:
    # INSECURE: MD5 for a security-relevant fingerprint.
    return hashlib.md5(card_number.encode()).hexdigest()


def score_rule(expression: str, context: dict) -> float:
    # INSECURE: eval on a rule expression — code injection.
    return float(eval(expression, {"__builtins__": {}}, context))


def build_agent() -> Agent:
    return Agent(
        role="Fraud Reviewer",
        goal="Decide hold/release/escalate for flagged NovaPay transactions.",
        backstory="A senior risk analyst that never sleeps.",
        llm=FRAUD_MODEL,
        tools=[],  # wired to MCP servers declared in .cursor/mcp.json
    )


def review(transaction: dict) -> dict:
    agent = build_agent()
    task = Task(
        description=f"Review transaction {transaction['id']} for fraud.",
        agent=agent,
        expected_output="hold | release | escalate + rationale",
    )
    crew = Crew(agents=[agent], tasks=[task])
    result = crew.kickoff()
    return {"decision": str(result), "fp": _fingerprint(transaction.get("card", ""))}


if __name__ == "__main__":
    print(review({"id": "txn_1001", "card": "4111111111111111", "amount": 9400}))
    _ = os.environ.get("NOVAPAY_ENV")
