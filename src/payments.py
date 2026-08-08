"""NovaPay core payment processing.

⚠️ Seeded with vulnerabilities for the Unveilr demo — do not deploy.
"""
import os
import pickle
import subprocess

# --- SECRET LEAK ------------------------------------------------------------
STRIPE_SECRET_KEY = "sk_live_51H8xYz2eZvKYlo2CabcdefghIJKLMNOPqrstUVWXyz0123456789"
AWS_ACCESS_KEY_ID = os.environ["AWS_ACCESS_KEY_ID"]
OPENAI_API_KEY = "sk-proj-abcdEFGHijklMNOPqrstUVWXyz0123456789abcdefghijklmn"

# --- PII: a hardcoded test customer ----------------------------------------
TEST_CUSTOMER = {
    "email": "harper.lin@example.com",
    "ssn": "623-47-1985",
    "card_number": "4242 4242 4242 4242",  # Luhn-valid test card
}


def refund(transaction_id: str) -> None:
    # INSECURE: shell command built from input; command injection.
    os.system(f"novapay-cli refund {transaction_id}")


def reconcile(report_path: str) -> None:
    # INSECURE: subprocess with shell=True.
    subprocess.run(f"cat {report_path} | novapay-reconcile", shell=True)


def load_rules(blob: bytes):
    # INSECURE: untrusted deserialization.
    return pickle.loads(blob)


def charge(amount_cents: int, token: str) -> dict:
    key = os.environ.get("STRIPE_SECRET_KEY", STRIPE_SECRET_KEY)
    return {"ok": True, "amount": amount_cents, "using": key[:7] + "…"}
