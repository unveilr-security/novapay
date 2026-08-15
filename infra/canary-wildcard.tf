resource "aws_iam_policy" "canary_wildcard" {
  name   = "canary-wildcard"
  policy = jsonencode({
    Statement = [{ Effect = "Allow", Action = "*", Resource = "*" }]
  })
}
