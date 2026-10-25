data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Use name_prefix if provided, otherwise empty string
  resource_prefix    = var.name_prefix != "" ? "${var.name_prefix}-" : ""
  log_retention_days = 365

  common_tags = {
    function  = "cluster-provisioning"
    module    = "codebuild-notifications"
    ManagedBy = "terraform"
  }
}

# Lambda function to format and send Slack notifications for CodePipeline failures
data "archive_file" "slack_notifier" {
  type        = "zip"
  output_path = "${path.module}/slack_notifier.zip"

  source {
    content  = <<-EOF
      import json
      import urllib3
      import os
      import boto3
      import logging

      # Configure logging
      logger = logging.getLogger()
      logger.setLevel(logging.INFO)

      # Configure HTTP with timeout and retries
      http = urllib3.PoolManager(
          timeout=urllib3.Timeout(connect=5.0, read=10.0),
          retries=urllib3.Retry(total=3, backoff_factor=0.3)
      )

      # Initialize SSM client
      ssm_client = boto3.client('ssm', region_name=os.environ.get('AWS_REGION_NAME', os.environ.get('AWS_REGION', 'us-east-1')))

      def get_webhook_url():
          """Retrieve Slack webhook URL from SSM Parameter Store"""
          param_name = os.environ['SLACK_WEBHOOK_SSM_PARAM']
          try:
              response = ssm_client.get_parameter(
                  Name=param_name,
                  WithDecryption=True
              )
              return response['Parameter']['Value']
          except Exception as e:
              logger.error(f"get_webhook_url: Failed to retrieve SSM parameter '{param_name}': {str(e)}", exc_info=True)
              raise

      def lambda_handler(event, context):
          # Extract CodeBuild build details early for logging context
          detail = event.get('detail', {})
          project_name = detail.get('project-name', 'Unknown')
          build_id = detail.get('build-id', 'Unknown')
          build_status = detail.get('build-status', 'Unknown')
          region = event.get('region', 'Unknown')
          account = event.get('account', 'Unknown')
          time = event.get('time', 'Unknown')

          logger.info(f"lambda_handler: Processing CodeBuild failure notification for project='{project_name}', build_id='{build_id}', status='{build_status}'")

          try:
              # Retrieve webhook URL from SSM Parameter Store
              webhook_url = get_webhook_url()
          except Exception as e:
              logger.error(f"lambda_handler: Failed to retrieve webhook URL for project='{project_name}', build_id='{build_id}'", exc_info=True)
              raise

          # Build console URL for the failed CodeBuild build
          console_url = f"https://console.aws.amazon.com/codesuite/codebuild/{account}/projects/{project_name}/build/{build_id}/?region={region}"

          # Build Slack message with rich formatting
          slack_message = {
              "text": f":x: CodeBuild Failure: {project_name}",
              "blocks": [
                  {
                      "type": "header",
                      "text": {
                          "type": "plain_text",
                          "text": f":x: CodeBuild Failed: {project_name}"
                      }
                  },
                  {
                      "type": "section",
                      "fields": [
                          {
                              "type": "mrkdwn",
                              "text": f"*Project:*\n{project_name}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Status:*\n{build_status}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Build ID:*\n{build_id}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Region:*\n{region}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Account:*\n{account}"
                          },
                          {
                              "type": "mrkdwn",
                              "text": f"*Time:*\n{time}"
                          }
                      ]
                  },
                  {
                      "type": "actions",
                      "elements": [
                          {
                              "type": "button",
                              "text": {
                                  "type": "plain_text",
                                  "text": "View Build in AWS Console"
                              },
                              "url": console_url,
                              "style": "danger"
                          }
                      ]
                  }
              ]
          }

          try:
              # Send to Slack with timeout and error handling
              encoded_data = json.dumps(slack_message).encode('utf-8')
              response = http.request(
                  'POST',
                  webhook_url,
                  body=encoded_data,
                  headers={'Content-Type': 'application/json'}
              )

              # Check if response is successful (2xx)
              if 200 <= response.status < 300:
                  logger.info(f"lambda_handler: Successfully sent notification to Slack for project='{project_name}', build_id='{build_id}', slack_status={response.status}")
                  return {
                      'statusCode': 200,
                      'body': json.dumps({
                          'message': 'Notification sent to Slack successfully',
                          'project': project_name,
                          'slack_status': response.status
                      })
                  }
              else:
                  # Non-2xx response from Slack - log and raise to trigger retry
                  response_body = response.data.decode('utf-8', errors='replace')
                  logger.error(f"lambda_handler: Slack webhook returned non-2xx status for project='{project_name}', build_id='{build_id}', slack_status={response.status}, response_body='{response_body}'")
                  raise Exception(f"Slack webhook returned status {response.status}: {response_body}")

          except urllib3.exceptions.TimeoutError as e:
              logger.error(f"lambda_handler: Timeout sending notification to Slack for project='{project_name}', build_id='{build_id}'", exc_info=True)
              raise
          except urllib3.exceptions.HTTPError as e:
              logger.error(f"lambda_handler: HTTP error sending notification to Slack for project='{project_name}', build_id='{build_id}'", exc_info=True)
              raise
          except Exception as e:
              logger.error(f"lambda_handler: Unexpected error sending notification for project='{project_name}', build_id='{build_id}'", exc_info=True)
              raise
    EOF
    filename = "lambda_function.py"
  }
}

# IAM role for Lambda function
resource "aws_iam_role" "slack_notifier" {
  name = "${local.resource_prefix}slack-notifier-role"
  tags = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# IAM policy for Lambda CloudWatch Logs
resource "aws_iam_role_policy" "slack_notifier_logs" {
  role = aws_iam_role.slack_notifier.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.resource_prefix}pipeline-failure-notifier:*"
      }
    ]
  })
}

# IAM policy for Lambda to read SSM parameters
resource "aws_iam_role_policy" "slack_notifier_ssm" {
  role = aws_iam_role.slack_notifier.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.slack_webhook_ssm_param}"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = "arn:aws:kms:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:key/*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${data.aws_region.current.region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Lambda function
resource "aws_lambda_function" "slack_notifier" {
  filename         = data.archive_file.slack_notifier.output_path
  function_name    = "${local.resource_prefix}pipeline-failure-notifier"
  role             = aws_iam_role.slack_notifier.arn
  handler          = "lambda_function.lambda_handler"
  source_code_hash = data.archive_file.slack_notifier.output_base64sha256
  runtime          = "python3.12"
  tags             = local.common_tags
  timeout          = 30

  environment {
    variables = {
      SLACK_WEBHOOK_SSM_PARAM = var.slack_webhook_ssm_param
      AWS_REGION_NAME         = data.aws_region.current.region
    }
  }

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "slack_notifier" {
  name              = "/aws/lambda/${aws_lambda_function.slack_notifier.function_name}"
  retention_in_days = local.log_retention_days
  tags              = local.common_tags

  lifecycle {
    ignore_changes = [tags, tags_all]
  }
}

# EventBridge rule to detect CodeBuild failures (FAILED only — exclude STOPPED/TIMED_OUT)
resource "aws_cloudwatch_event_rule" "pipeline_failure" {
  name        = "${local.resource_prefix}codebuild-failure-detection"
  description = "Detects when any CodeBuild build fails"
  tags        = local.common_tags

  event_pattern = jsonencode({
    source      = ["aws.codebuild"]
    detail-type = ["CodeBuild Build State Change"]
    detail = {
      project-name = var.project_names
      build-status = ["FAILED"]
    }
  })
}

# EventBridge target to invoke Lambda
resource "aws_cloudwatch_event_target" "slack_notifier" {
  rule      = aws_cloudwatch_event_rule.pipeline_failure.name
  target_id = "SendToSlackLambda"
  arn       = aws_lambda_function.slack_notifier.arn
}

# Permission for EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_failure.arn
}
