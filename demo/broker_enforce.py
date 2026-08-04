#!/usr/bin/env python3
"""NovaPay fraud agent — the privileged AWS action, governed by Unveilr.

The fraud agent must read a flagged transaction (card + PII) from S3 to review
it. Today it would use the hardcoded standing key from ``agents/fraud_agent.py``
(``AKIA…`` with ``s3:*`` — see ``infra/main.tf``). This harness routes that ONE
action through Unveilr and demonstrates the wedge:

    monitor  →  observe the decision the control WOULD take. Nothing enforced,
                the agent is not blocked. Watch it be right, safely.

    enforce  →  the standing key is DENIED. Unveilr's PDP returns ``scoped_token``;
                the broker mints a short-lived STS credential scoped to exactly
                this object; the in-scope read SUCCEEDS with it; the out-of-scope
                decoy read is DENIED (the boundary held); CloudTrail correlation
                proves ``bounded_authority_proven``. Every step is sealed into the
                hash-chained evidence ledger.

Config (env):
    UNVEILR_API           e.g. http://localhost:8080
    UNVEILR_AGENT_TOKEN   the fraud agent's minted uvt_… credential
    BROKER_BUCKET         S3 bucket from provision.sh
    BROKER_OBJECT_KEY     in-scope key   (default flagged/txn-88431.json)
    BROKER_DECOY_KEY      out-of-scope key (default flagged/txn-99999.json)
    AWS_REGION            default us-east-1
    UNVEILR_SERVER        logical server label for the call (default aws-prod)

Run:  python demo/broker_enforce.py --mode monitor
      python demo/broker_enforce.py --mode enforce
"""
from __future__ import annotations

import argparse
import json
import os
import sys

try:
    import requests
except ImportError:  # pragma: no cover
    sys.exit("pip install requests boto3")

API = os.environ.get("UNVEILR_API", "http://localhost:8080").rstrip("/")
TOKEN = os.environ.get("UNVEILR_AGENT_TOKEN", "")
BUCKET = os.environ.get("BROKER_BUCKET", "")
OBJECT_KEY = os.environ.get("BROKER_OBJECT_KEY", "flagged/txn-88431.json")
DECOY_KEY = os.environ.get("BROKER_DECOY_KEY", "flagged/txn-99999.json")
REGION = os.environ.get("AWS_REGION", "us-east-1")
SERVER = os.environ.get("UNVEILR_SERVER", "aws-prod")

C = {"g": "\033[1;32m", "r": "\033[1;31m", "c": "\033[1;36m", "y": "\033[1;33m", "x": "\033[0m"}


def _say(color: str, msg: str) -> None:
    print(f"{C[color]}{msg}{C['x']}")


def _object_arn(key: str) -> str:
    return f"arn:aws:s3:::{BUCKET}/{key}"


def _govern_check() -> dict:
    """Ask Unveilr whether the fraud agent may read the flagged object, and how."""
    if not (TOKEN and BUCKET):
        sys.exit("set UNVEILR_AGENT_TOKEN and BROKER_BUCKET (see provision.sh output)")
    body = {
        "tool": "aws.s3.GetObject",
        "server": SERVER,
        "arguments": {
            "resourceArn": _object_arn(OBJECT_KEY),
            "bucket": BUCKET,
            "key": OBJECT_KEY,
        },
    }
    r = requests.post(
        f"{API}/v1/govern/check",
        headers={"Authorization": f"Bearer {TOKEN}", "content-type": "application/json"},
        json=body,
        timeout=30,
    )
    if r.status_code != 200:
        sys.exit(f"govern/check {r.status_code}: {r.text}")
    return r.json()


def _s3_get(cred: dict, key: str) -> tuple[bool, str]:
    """GetObject with the BROKER-ISSUED scoped credential (never the standing key)."""
    import boto3
    from botocore.exceptions import ClientError

    s3 = boto3.client(
        "s3",
        region_name=REGION,
        aws_access_key_id=cred["accessKeyId"],
        aws_secret_access_key=cred["secretAccessKey"],
        aws_session_token=cred["sessionToken"],
    )
    try:
        obj = s3.get_object(Bucket=BUCKET, Key=key)
        return True, obj["Body"].read().decode("utf-8")
    except ClientError as exc:
        return False, exc.response["Error"]["Code"]


def _correlate(credential_id: str) -> dict | None:
    r = requests.post(
        f"{API}/v1/broker/credentials/{credential_id}/correlate",
        headers={"Authorization": f"Bearer {TOKEN}", "content-type": "application/json"},
        timeout=60,
    )
    return r.json() if r.status_code == 200 else None


def monitor() -> int:
    _say("y", "── MONITOR MODE ─ observe only, nothing is enforced ──")
    print(f"  fraud agent intends: aws.s3.GetObject  {_object_arn(OBJECT_KEY)}")
    print("  today (ungoverned):  reads it with the standing key AKIA… (s3:* everywhere)")
    d = _govern_check()
    _say("c", f"  Unveilr WOULD decide: {d['decision']}  —  {d.get('reason', '')}")
    print("  → not enforced: the agent is not blocked, no credential minted.")
    print("    This decision is sealed as evidence so you can watch it be right,")
    print("    then flip to --mode enforce. (Re-run any time.)")
    return 0


def enforce() -> int:
    _say("c", "── ENFORCE MODE ─ the standing key is denied ──")
    d = _govern_check()
    decision = d["decision"]

    if decision == "deny":
        _say("r", f"  DENIED: {d.get('reason', '')}")
        print("  The fraud agent may not perform this action. No credential issued.")
        return 2
    if decision == "allow":
        _say("y", "  Decision was ALLOW — no scoping applied. Seed the scoped_token")
        print("  policy (SCENARIO_BROKER_AWS.md step 5) so this becomes scoped_token.")
        return 1
    if decision != "scoped_token":
        _say("y", f"  Unexpected decision: {decision}"); return 1

    cred = d.get("credential") or {}
    if cred.get("error"):
        _say("r", f"  broker error: {cred['error']}  (check BROKER_ROLE_ARN + API AWS creds)")
        return 3
    _say("g", "  standing key DENIED → broker issued a scoped, short-lived credential")
    print(f"    credentialId : {cred.get('credentialId')}")
    print(f"    accessKeyId  : {cred.get('accessKeyId')}   (temporary ASIA…)")
    print(f"    scoped to    : s3:GetObject on {_object_arn(OBJECT_KEY)}")
    print(f"    expires      : {cred.get('expiration')}")

    ok, in_scope = _s3_get(cred, OBJECT_KEY)
    if ok:
        txn = json.loads(in_scope)
        _say("g", f"  ✓ IN-SCOPE read succeeded — txn {txn['id']} ({txn['status']}, ${txn['amount']})")
    else:
        _say("r", f"  ✗ in-scope read failed unexpectedly: {in_scope}")
        return 3

    denied, code = _s3_get(cred, DECOY_KEY)
    if not denied and code == "AccessDenied":
        _say("g", f"  ✓ OUT-OF-SCOPE decoy read DENIED ({code}) — the boundary held")
    else:
        _say("r", f"  ✗ decoy read was NOT denied (got: {code or 'success'}) — scope too broad")
        return 3

    verdict = _correlate(cred.get("credentialId", ""))
    if verdict:
        v = verdict.get("verdict", "?")
        color = "g" if v == "bounded_authority_proven" else "y"
        _say(color, f"  CloudTrail correlation: {v}")
        print(f"    {json.dumps({k: verdict[k] for k in verdict if k != 'raw'}, default=str)[:300]}")
        if v != "bounded_authority_proven":
            print("    (data events can take 5–15 min; re-run correlate, or provision --with-cloudtrail)")
    else:
        print("  correlation unavailable (set CLOUDTRAIL_ENABLED=true + provision --with-cloudtrail)")

    _say("g", "\n  Bounded authority, proven — and every step sealed in the evidence ledger.")
    print("  Verify:  curl -s $UNVEILR_API/v1/evidence/verify")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="NovaPay fraud agent — governed AWS read")
    ap.add_argument("--mode", choices=["monitor", "enforce"], default="monitor")
    args = ap.parse_args()
    _say("c", f"Unveilr {API} · bucket {BUCKET or '(unset)'} · region {REGION}")
    return monitor() if args.mode == "monitor" else enforce()


if __name__ == "__main__":
    raise SystemExit(main())
