# NovaPay infrastructure.
# ⚠️ Seeded with misconfigurations for the Unveilr demo — do not apply.

provider "aws" {
  region = "us-east-1"
}

# IAC: public S3 bucket ACL.
resource "aws_s3_bucket" "statements" {
  bucket = "novapay-customer-statements"
}

resource "aws_s3_bucket_acl" "statements" {
  bucket = aws_s3_bucket.statements.id
  acl    = "public-read"
}

# IAC: unencrypted + publicly accessible RDS.
resource "aws_db_instance" "ledger" {
  identifier          = "novapay-ledger"
  engine              = "postgres"
  instance_class      = "db.t3.medium"
  publicly_accessible = true
  storage_encrypted   = false
  username            = "novapay"
  password            = "changeme123"
}

# IAC: security group open to the world.
resource "aws_security_group" "api" {
  name = "novapay-api"
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAC + AI-IAM: over-broad IAM policy including bedrock:*.
resource "aws_iam_role_policy" "fraud_agent" {
  name = "novapay-fraud-agent"
  role = "novapay-fraud-agent-role"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "*", Resource = "*" },
      { Effect = "Allow", Action = "bedrock:InvokeModel", Resource = "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0" },
      { Effect = "Allow", Action = "sagemaker:InvokeEndpoint", Resource = "arn:aws:sagemaker:us-east-1:*:endpoint/novapay-risk-score" },
    ]
  })
}

# AI service: Amazon Bedrock (the fraud agent's model host).
resource "aws_bedrockagent_agent" "fraud" {
  agent_name = "novapay-fraud"
  foundation_model = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

# AI service: SageMaker endpoint for the risk-scoring model.
resource "aws_sagemaker_endpoint" "risk_score" {
  name                 = "novapay-risk-score"
  endpoint_config_name = "novapay-risk-score-config"
}

# AI service: Azure OpenAI (support agent fallback).
resource "azurerm_cognitive_account" "support" {
  name                = "novapay-support-openai"
  kind                = "OpenAI"
  sku_name            = "S0"
  resource_group_name = "novapay-rg"
  location            = "eastus"
}
