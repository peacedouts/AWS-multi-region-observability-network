###############################################################################
# modules/iam_network_deployer  (bootstrapped once into EVERY account)
#
# The only principal allowed to change the network (enforced by SCP
# policies/scp/protect-network-baseline.json). It is assumed by the CI
# pipeline role (GitHub Actions via OIDC) and nothing else.
#
# Least privilege by construction: it can manage networking and the
# monitoring plumbing, and is explicitly denied the data plane through a
# permissions boundary. The network pipeline can build the road to the data;
# it can never read the data.
###############################################################################

variable "role_name" {
  type    = string
  default = "terraform-network-deployer"
}

variable "trusted_pipeline_role_arns" {
  type        = list(string)
  description = "CI role(s) allowed to assume this role (e.g. the GitHub OIDC role in the tooling account)."
}

variable "github_repository" {
  type        = string
  description = "owner/repo, recorded as a session tag requirement for traceability."
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = var.trusted_pipeline_role_arns
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/repository"
      values   = [var.github_repository]
    }
  }
}

# Permissions boundary: hard ceiling regardless of attached policies.
data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "AllowNetworkAndMonitoringPlane"
    actions   = ["ec2:*", "logs:*", "cloudwatch:*", "events:*", "sns:*", "kms:*", "lambda:*", "config:*", "iam:*", "elasticloadbalancing:*", "acm:*", "acm-pca:*", "route53:*", "globalaccelerator:*", "s3:*", "secretsmanager:DescribeSecret", "sts:*"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyDataPlane"
    effect = "Deny"
    actions = [
      "rds:*", "rds-db:connect", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan",
      "secretsmanager:GetSecretValue", "kms:Decrypt",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "DenyEventDataBuckets"
    effect    = "Deny"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:PutBucketReplication"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::*-event-data-*"]
  }

  statement {
    sid       = "NoPrivilegeEscalation"
    effect    = "Deny"
    actions   = ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }

  statement {
    sid     = "CanOnlyCreateServiceRolesItOwns"
    effect  = "Deny"
    actions = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy"]
    not_resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/*-flow-logs",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/*-connectivity-probe",
    ]
  }
}

resource "aws_iam_policy" "boundary" {
  name   = "${var.role_name}-boundary"
  policy = data.aws_iam_policy_document.boundary.json
  tags   = var.tags
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = 3600
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "network_admin" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/job-function/NetworkAdministrator"
}

data "aws_iam_policy_document" "extras" {
  statement {
    sid = "MonitoringPlumbing"
    actions = [
      "logs:*", "cloudwatch:*", "events:*", "sns:*", "lambda:*", "config:PutConfigRule",
      "config:DeleteConfigRule", "config:DescribeConfigRules", "kms:CreateKey", "kms:Describe*",
      "kms:Get*", "kms:List*", "kms:PutKeyPolicy", "kms:EnableKeyRotation", "kms:TagResource",
      "kms:ScheduleKeyDeletion", "kms:CreateGrant",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ServiceRolesForFlowLogsAndProbe"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:GetRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PassRole",
      "iam:TagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:CreatePolicy",
      "iam:GetPolicy", "iam:GetPolicyVersion",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/*-flow-logs",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/*-connectivity-probe",
    ]
  }
}

resource "aws_iam_role_policy" "extras" {
  name   = "network-pipeline-extras"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.extras.json
}

output "role_arn" {
  value = aws_iam_role.this.arn
}
