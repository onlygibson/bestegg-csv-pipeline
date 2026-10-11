# CSV pipeline, the way Steve described the problem:
#   someone drops a CSV in S3 -> it gets processed -> good rows to a database,
#   bad rows kept for audit -> an email says it's done.
#
#   S3 (incoming/) --event--> SQS --> Lambda --> DynamoDB      (good rows)
#                              |         |----> S3 rejected/   (bad rows, kept for audit)
#                              |         '----> SNS email      (summary)
#                              '--after 3 failed tries--> dead-letter queue --> alarm email
#
# Everything is encrypted with one customer-managed KMS key.

data "aws_caller_identity" "current" {}

locals {
  name            = "csv-pipeline-${var.environment}"
  account_id      = data.aws_caller_identity.current.account_id
  incoming_prefix = "incoming/"
  reject_prefix   = "rejected/"
}

# ---------------------------------------------------------------------------
# Encryption key
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "kms" {
  # In a KMS key policy, "Resource": "*" means "this key only". It is the required
  # form, not a wildcard over the account, so these three findings are false positives.
  #checkov:skip=CKV_AWS_109:Key policy. Resource "*" refers to this key only.
  #checkov:skip=CKV_AWS_111:Key policy. Resource "*" refers to this key only.
  #checkov:skip=CKV_AWS_356:Key policy. Resource "*" refers to this key only.
  statement {
    sid = "AccountAdministration"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Two AWS services write into encrypted resources on our behalf:
  #   - S3 puts event messages into the encrypted queue
  #   - CloudWatch alarms publish to the encrypted SNS topic
  # Without this statement both fail silently. Easy one to forget.
  statement {
    sid = "AwsServicesWritingEncryptedMessages"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com", "cloudwatch.amazonaws.com"]
    }
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
  }

  statement {
    sid = "CloudWatchLogs"
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "main" {
  description             = "${local.name} encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

# ---------------------------------------------------------------------------
# S3 bucket: incoming/ for new files, rejected/ for bad rows
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "incoming" {
  #checkov:skip=CKV_AWS_18:Practice project. Access is recorded by CloudTrail; server access logs add cost without much value here.
  #checkov:skip=CKV_AWS_144:Single-region practice project, so no cross-region replication.
  bucket        = "${local.name}-${local.account_id}-${var.region}"
  force_destroy = true # lets "terraform destroy" empty the bucket; turn off for real data
}

resource "aws_s3_bucket_versioning" "incoming" {
  bucket = aws_s3_bucket.incoming.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "incoming" {
  bucket = aws_s3_bucket.incoming.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true # far fewer KMS calls, so cheaper
  }
}

resource "aws_s3_bucket_public_access_block" "incoming" {
  bucket                  = aws_s3_bucket.incoming.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "incoming" {
  bucket = aws_s3_bucket.incoming.id
  rule {
    id     = "tidy-up"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "incoming_bucket" {
  statement {
    sid    = "DenyUnencryptedConnections"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.incoming.arn, "${aws_s3_bucket.incoming.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "incoming" {
  bucket     = aws_s3_bucket.incoming.id
  policy     = data.aws_iam_policy_document.incoming_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.incoming]
}

# ---------------------------------------------------------------------------
# SQS: a buffer between S3 and the Lambda, plus a dead-letter queue
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                              = "${local.name}-dlq"
  message_retention_seconds         = 1209600 # 14 days, the maximum, to give time to investigate
  kms_master_key_id                 = aws_kms_key.main.arn
  kms_data_key_reuse_period_seconds = 300
}

resource "aws_sqs_queue" "main" {
  name = "${local.name}-queue"
  # Must be longer than the Lambda timeout, otherwise a message can be handed
  # out again while the first attempt is still running. AWS suggests 6x.
  visibility_timeout_seconds        = var.lambda_timeout_seconds * 6
  message_retention_seconds         = 345600 # 4 days
  kms_master_key_id                 = aws_kms_key.main.arn
  kms_data_key_reuse_period_seconds = 300

  # After 3 failed attempts, a message moves to the dead-letter queue.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid = "AllowOnlyOurBucketToSendEvents"
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.main.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.incoming.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  policy    = data.aws_iam_policy_document.queue.json
}

resource "aws_s3_bucket_notification" "incoming" {
  bucket = aws_s3_bucket.incoming.id

  queue {
    queue_arn = aws_sqs_queue.main.arn
    events    = ["s3:ObjectCreated:*"]
    # Only new CSVs in incoming/. The Lambda writes to rejected/ in the same
    # bucket; without this filter it would trigger itself in a loop.
    filter_prefix = local.incoming_prefix
    filter_suffix = ".csv"
  }

  depends_on = [aws_sqs_queue_policy.main]
}

# ---------------------------------------------------------------------------
# DynamoDB: where good rows end up
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "records" {
  name         = "${local.name}-records"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "record_id" # "<file>#<row id>", so a retry overwrites instead of duplicating

  attribute {
    name = "record_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }
}

# ---------------------------------------------------------------------------
# SNS: processing summaries and alarms, by email
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "notifications" {
  name              = "${local.name}-notifications"
  kms_master_key_id = aws_kms_key.main.arn
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.notifications.arn
  protocol  = "email"
  endpoint  = var.notify_email
}

# ---------------------------------------------------------------------------
# Lambda: the processor
# ---------------------------------------------------------------------------

data "archive_file" "lambda" {
  type             = "zip"
  source_file      = "${path.module}/../lambda/handler.py"
  output_path      = "${path.module}/build/handler.zip"
  output_file_mode = "0644" # same zip on every computer, so GitHub doesn't see a change
}

# Created before the function, so it has a retention period and encryption.
# Otherwise Lambda makes its own log group that keeps logs forever.
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-processor"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.main.arn
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.name}-processor"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Least privilege: each permission is limited to the one resource it needs.
data "aws_iam_policy_document" "lambda" {
  statement {
    sid = "ReadTheQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.main.arn]
  }

  statement {
    sid       = "ReadIncomingFilesOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.incoming.arn}/${local.incoming_prefix}*"]
  }

  statement {
    sid       = "WriteRejectedRowsOnly"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.incoming.arn}/${local.reject_prefix}*"]
  }

  statement {
    sid       = "WriteRecords"
    actions   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"]
    resources = [aws_dynamodb_table.records.arn]
  }

  statement {
    sid       = "SendNotifications"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]
  }

  statement {
    sid       = "UseTheEncryptionKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "processor"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_lambda_function" "processor" {
  #checkov:skip=CKV_AWS_115:Concurrency is capped on the SQS event source mapping instead. Reserved concurrency fails on new accounts with a 10-concurrency quota.
  #checkov:skip=CKV_AWS_116:Failed messages go to the SQS dead-letter queue. An async Lambda DLQ does not apply to SQS-triggered functions.
  #checkov:skip=CKV_AWS_117:The function only calls AWS APIs. No private resources, so no VPC needed.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope for a practice project.
  function_name    = "${local.name}-processor"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = var.lambda_timeout_seconds
  memory_size      = 256
  kms_key_arn      = aws_kms_key.main.arn

  environment {
    variables = {
      TABLE_NAME      = aws_dynamodb_table.records.name
      TOPIC_ARN       = aws_sns_topic.notifications.arn
      INCOMING_PREFIX = local.incoming_prefix
      REJECT_PREFIX   = local.reject_prefix
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

resource "aws_lambda_event_source_mapping" "queue" {
  event_source_arn = aws_sqs_queue.main.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 5

  # The function reports which messages failed, so only those are retried.
  function_response_types = ["ReportBatchItemFailures"]

  # At most 5 copies run at once, so a flood of files can't overwhelm anything.
  scaling_config {
    maximum_concurrency = 5
  }
}

# ---------------------------------------------------------------------------
# Alarms: all of them email the same SNS topic
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.name}-dlq-not-empty"
  alarm_description   = "A file failed 3 times and is now in the dead-letter queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.notifications.arn]
}

resource "aws_cloudwatch_metric_alarm" "files_waiting_too_long" {
  alarm_name          = "${local.name}-files-waiting"
  alarm_description   = "A file has been waiting in the queue too long. Processing is stuck or too slow."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.main.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.notifications.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_crashed" {
  alarm_name          = "${local.name}-lambda-crashed"
  alarm_description   = "The function itself crashed or timed out. Bad files don't count here; they show up in the dead-letter queue."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.processor.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.notifications.arn]
}
