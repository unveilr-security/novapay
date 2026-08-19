"""Deliberately denied change, used to prove C-003 end to end.

Contains a credential-shaped literal so the PR check must conclude failure.
The value is AWS's own published documentation key — never a real credential.
"""
AWS_ACCESS_KEY_ID = "AKIAIOSFODNN7EXAMPLE"
