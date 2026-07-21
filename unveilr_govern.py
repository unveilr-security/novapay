"""Drop-in Unveilr governance for NON-MCP agent tools.

This sample re-exports the published SDK under ``sdk/python`` so NovaPay demos
stay in sync with partner on-ramps.

    from unveilr_govern import govern

    @govern(tool="ledger.query")
    def query_ledger(sql: str) -> list: ...

Set UNVEILR_API and UNVEILR_AGENT_TOKEN. Prefer::

    pip install -e ../../sdk/python
    from unveilr import govern
"""
from __future__ import annotations

import sys
from pathlib import Path

# Allow running the sample without a prior pip install of the SDK.
_SDK = Path(__file__).resolve().parents[2] / "sdk" / "python"
if _SDK.is_dir() and str(_SDK) not in sys.path:
    sys.path.insert(0, str(_SDK))

from unveilr import ToolCallDenied, check, govern  # noqa: E402

__all__ = ["ToolCallDenied", "check", "govern"]
