output "lambda_function_arn" {
  description = "ARN of the Lambda function that sends Slack notifications"
  value       = aws_lambda_function.slack_notifier.arn
}

output "eventbridge_rule_arn" {
  description = "ARN of the EventBridge rule that detects pipeline failures"
  value       = aws_cloudwatch_event_rule.pipeline_failure.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.slack_notifier.function_name
}
