FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
# ⚠️ AI provider key baked into the image env — Unveilr flags this.
ENV BEDROCK_REGION=us-east-1
ENV OPENAI_API_KEY=sk-proj-bakedintoimage0123456789abcdefghij
CMD ["python", "-m", "src.payments"]
