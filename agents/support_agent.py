"""NovaPay AI support agent — answers customer questions about payments and
disputes. Built with LangChain; uses GPT-4o.

⚠️ Seeded with vulnerabilities for the Unveilr demo — do not deploy.
"""
import pickle
import ssl

import requests
from langchain.agents import AgentExecutor, create_tool_calling_agent
from langchain_openai import ChatOpenAI

SUPPORT_MODEL = "gpt-4o"

# INSECURE: TLS verification disabled for the internal knowledge base.
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE


def load_memory(blob: bytes):
    # INSECURE: deserializing untrusted data.
    return pickle.loads(blob)


def fetch_kb(url: str) -> str:
    # INSECURE: verify=False disables certificate validation.
    return requests.get(url, verify=False, timeout=10).text


def build_agent() -> AgentExecutor:
    llm = ChatOpenAI(model=SUPPORT_MODEL, temperature=0)
    agent = create_tool_calling_agent(llm, tools=[], prompt=None)
    return AgentExecutor(agent=agent, tools=[])


def answer(question: str) -> str:
    executor = build_agent()
    return executor.invoke({"input": question})["output"]
