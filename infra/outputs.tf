output "bucket" {
  description = "Upload CSV files to s3://<bucket>/incoming/"
  value       = aws_s3_bucket.incoming.bucket
}

output "table" {
  value = aws_dynamodb_table.records.name
}

output "queue_url" {
  value = aws_sqs_queue.main.url
}

output "dead_letter_queue_url" {
  value = aws_sqs_queue.dlq.url
}

output "dead_letter_queue_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "topic_arn" {
  value = aws_sns_topic.notifications.arn
}

output "function_name" {
  value = aws_lambda_function.processor.function_name
}
