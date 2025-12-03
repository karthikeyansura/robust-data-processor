terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# STORAGE (DynamoDB)

resource "aws_dynamodb_table" "logs_table" {
  name         = "MultiTenantLogs"
  billing_mode = "PAY_PER_REQUEST" # Serverless - scales to zero cost

  hash_key  = "tenant_id" # Partition Key - ensures tenant isolation
  range_key = "log_id"    # Sort Key - unique per log

  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "log_id"
    type = "S"
  }

  tags = {
    Project = "robust-processor"
  }
}

# MESSAGE BROKER (SQS)

resource "aws_sqs_queue" "dlq" {
  name                      = "ingest-dlq"
  message_retention_seconds = 1209600 # 14 days
}

resource "aws_sqs_queue" "ingest_queue" {
  name                       = "ingest-queue"
  visibility_timeout_seconds = 900 # Must be >= Lambda timeout
  receive_wait_time_seconds  = 20 # Long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3 # Retry 3x before DLQ
  })
}

# IAM ROLES

# Ingest Lambda Role
resource "aws_iam_role" "ingest_role" {
  name = "ingest_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ingest_basic" {
  role       = aws_iam_role.ingest_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "ingest_sqs_policy" {
  name = "ingest_sqs_write"
  role = aws_iam_role.ingest_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.ingest_queue.arn
    }]
  })
}

# Worker Lambda Role
resource "aws_iam_role" "worker_role" {
  name = "worker_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "worker_basic" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "worker_policy" {
  name = "worker_processing_policy"
  role = aws_iam_role.worker_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.ingest_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.logs_table.arn
      }
    ]
  })
}

# LAMBDA FUNCTIONS

resource "aws_lambda_function" "ingest_lambda" {
  filename         = "ingest.zip"
  function_name    = "IngestAPI"
  role             = aws_iam_role.ingest_role.arn
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  architectures    = ["x86_64"]
  source_code_hash = fileexists("ingest.zip") ? filebase64sha256("ingest.zip") : null
  timeout          = 10
  memory_size      = 256

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.ingest_queue.url
    }
  }
}

resource "aws_lambda_function" "worker_lambda" {
  filename         = "worker.zip"
  function_name    = "LogWorker"
  role             = aws_iam_role.worker_role.arn
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  architectures    = ["x86_64"]
  source_code_hash = fileexists("worker.zip") ? filebase64sha256("worker.zip") : null
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.logs_table.name
    }
  }
}

# SQS -> Worker Lambda Trigger
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn                   = aws_sqs_queue.ingest_queue.arn
  function_name                      = aws_lambda_function.worker_lambda.arn
  batch_size                         = 5
  function_response_types            = ["ReportBatchItemFailures"]
  maximum_batching_window_in_seconds = 0
}

# API GATEWAY

resource "aws_apigatewayv2_api" "http_api" {
  name          = "LogIngestGateway"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST"]
    allow_headers = ["Content-Type", "X-Tenant-ID"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ingest_lambda.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ingest_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /ingest"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# EVALUATOR ACCESS (to inspect DB)

resource "aws_iam_user" "evaluator" {
  name = "backend_evaluator"
}

resource "aws_iam_access_key" "evaluator_key" {
  user = aws_iam_user.evaluator.name
}

resource "aws_iam_user_policy" "evaluator_read_only" {
  name = "DynamoDBReadOnly"
  user = aws_iam_user.evaluator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:Scan",
        "dynamodb:Query",
        "dynamodb:BatchGetItem",
        "dynamodb:DescribeTable"
      ]
      Resource = aws_dynamodb_table.logs_table.arn
    }]
  })
}

# OUTPUTS

output "api_endpoint" {
  value       = "${aws_apigatewayv2_api.http_api.api_endpoint}/ingest"
  description = "POST your requests here"
}

output "dynamodb_table" {
  value = aws_dynamodb_table.logs_table.name
}

output "sqs_queue_url" {
  value = aws_sqs_queue.ingest_queue.url
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}

output "evaluator_access_key" {
  description = "Access Key ID for evaluator"
  value       = aws_iam_access_key.evaluator_key.id
}

output "evaluator_secret_key" {
  description = "Secret Key for evaluator"
  value       = aws_iam_access_key.evaluator_key.secret
  sensitive   = true
}