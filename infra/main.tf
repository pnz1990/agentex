terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "us-west-2"
}

locals {
  cluster_name  = "krombat"
  account_id    = "569190534191"
  oidc_provider = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

# ── ECR repo for agent runner image ─────────────────────────────────────────
resource "aws_ecr_repository" "runner" {
  name                 = "agentex/runner"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }


}

# ── IAM role for agent pods (IRSA via EKS Pod Identity) ─────────────────────
resource "aws_iam_role" "agent" {
  name = "agentex-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "agent_bedrock" {
  name = "agentex-bedrock-access"
  role = aws_iam_role.agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# EKS Pod Identity association
resource "aws_eks_pod_identity_association" "agent" {
  cluster_name    = local.cluster_name
  namespace       = "agentex"
  service_account = "agentex-agent-sa"
  role_arn        = aws_iam_role.agent.arn
}

# ── IAM role for GitHub Actions CI ──────────────────────────────────────────
resource "aws_iam_role" "github_actions" {
  name = "github-actions-agentex"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:pnz1990/agentex:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "agentex-ecr-push"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ]
      Resource = "*"
    }]
  })
}

# ── CloudWatch log group for agent output ────────────────────────────────────
resource "aws_cloudwatch_log_group" "agents" {
  name              = "/eks/krombat/agentex"
  retention_in_days = 30
}

resource "aws_cloudwatch_metric_alarm" "agent_failures" {
  alarm_name          = "agentex-agent-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pod_number_of_container_restarts"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "More than 5 agent pod restarts in 5 minutes"

  dimensions = {
    ClusterName = local.cluster_name
    Namespace   = "agentex"
  }
}

output "ecr_repository_url" {
  value = aws_ecr_repository.runner.repository_url
}

output "agent_role_arn" {
  value = aws_iam_role.agent.arn
}
