provider "aws" {
  region = "eu-north-1"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  required_version = ">= 1.9.0"
}

# Definir las colas SQS
resource "aws_sqs_queue" "shop_queue" {
  name = "shopQueue"
}

resource "aws_sqs_queue" "confirm_queue" {
  name = "confirmQueue"
}

resource "aws_sqs_queue" "cancel_queue" {
  name = "cancelQueue"
}

# IAM Role para las Lambdas
resource "aws_iam_role" "lambda_exec_role" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Políticas para las Lambdas
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "sqs_full_access" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

resource "aws_iam_role_policy_attachment" "ses_full_access" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSESFullAccess"
}

# Política para acceso a DynamoDB
resource "aws_iam_policy" "dynamodb_access" {
  name        = "DynamoDBAccessPolicy"
  description = "Policy to allow Lambda function to access DynamoDB"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",  # Permiso para UpdateItem
          "dynamodb:DeleteItem",
          "dynamodb:Scan",
          "dynamodb:Query"
        ]
        Resource = [
          "arn:aws:dynamodb:eu-north-1:241825613750:table/Productos",
          "arn:aws:dynamodb:eu-north-1:241825613750:table/Pedidos"  # Agrega acceso a la tabla Pedidos
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_dynamodb_policy" {
  policy_arn = aws_iam_policy.dynamodb_access.arn
  role       = aws_iam_role.lambda_exec_role.name
}

# Lambda StockChecker
resource "aws_lambda_function" "stock_checker_lambda" {
  function_name    = "StockCheckerLambda"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "com.demo.stocklambda.StockCheckerLambda::handleRequest"
  runtime          = "java17"
  memory_size      = 512
  timeout          = 15
  source_code_hash = filebase64sha256("../stocklambda/target/stocklambda-0.0.1-SNAPSHOT.jar")
  filename         = "../stocklambda/target/stocklambda-0.0.1-SNAPSHOT.jar"
  environment {
    variables = {
      CANCEL_QUEUE_URL  = aws_sqs_queue.cancel_queue.id
      CONFIRM_QUEUE_URL = aws_sqs_queue.confirm_queue.id
    }
  }

  depends_on = [
    aws_sqs_queue.shop_queue,
    aws_sqs_queue.confirm_queue,
    aws_sqs_queue.cancel_queue
  ]
}

# Lambda ConfirmLambdaFunction
resource "aws_lambda_function" "confirm_lambda" {
  function_name    = "ConfirmLambdaFunction"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "com.demo.confirmlambda.ConfirmLambda::handleRequest"
  runtime          = "java17"
  memory_size      = 512
  timeout          = 10
  source_code_hash = filebase64sha256("../confirmlambda/target/confirmlambda-0.0.1-SNAPSHOT.jar")
  filename         = "../confirmlambda/target/confirmlambda-0.0.1-SNAPSHOT.jar"
  environment {
    variables = {
      SENDER_EMAIL = "licinio@gmail.com"
    }
  }

  depends_on = [
    aws_sqs_queue.shop_queue,
    aws_sqs_queue.confirm_queue
  ]
}

# Asociar la cola SQS shopQueue con la funcion StockCheckerLambda
resource "aws_lambda_event_source_mapping" "stock_checker_sqs_trigger" {
  event_source_arn = aws_sqs_queue.shop_queue.arn
  function_name    = aws_lambda_function.stock_checker_lambda.arn
  batch_size       = 10  # El tamanho del lote de mensajes que la Lambda procesara por ejecucion
  enabled          = true
}

# Asociar la cola SQS confirmQueue con la funcion ConfirmLambdaFunction
resource "aws_lambda_event_source_mapping" "confirm_lambda_sqs_trigger" {
  event_source_arn = aws_sqs_queue.confirm_queue.arn
  function_name    = aws_lambda_function.confirm_lambda.arn
  batch_size       = 10  # El tamanho del lote de mensajes que la Lambda procesara por ejecucion
  enabled          = true
}

# EC2 Instance
resource "aws_instance" "app_server" {
  ami           = "ami-0129bfde49ddb0ed6"  # ID de AMI valido
  instance_type = "t3.micro"
  key_name      = "parClavesAWSshopsqs"  # Asegurate de que este sea tu par de claves

  iam_instance_profile = aws_iam_instance_profile.ec2_instance_profile.name
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  
  user_data = <<-EOF
			#!/bin/bash
			yum update -y
			yum install java-17-openjdk -y
			EOF
}

# Grupo de seguridad para EC2
resource "aws_security_group" "app_sg" {
  name        = "app_sg"
  description = "Permitir trafico para la aplicacion en EC2"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Para permitir SSH
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Para permitir acceso a tu aplicacion
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Role para EC2
resource "aws_iam_role" "ec2_role" {
  name = "ec2_access_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# Políticas para EC2
resource "aws_iam_role_policy_attachment" "ec2_dynamodb_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

resource "aws_iam_role_policy_attachment" "ec2_s3_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "ec2_sqs_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

# Perfil de instancia para EC2
resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "ec2_instance_profile"
  role = aws_iam_role.ec2_role.name
}

# DynamoDB Tables
resource "aws_dynamodb_table" "pedidos" {
  name           = "Pedidos"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "productos" {
  name           = "Productos"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_dynamodb_table" "usuarios" {
  name           = "Usuarios"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# Bucket S3 para almacenar imagenes de productos
resource "aws_s3_bucket" "imagenes_productos" {
  bucket = "s3imagenesproductos"
}

# Bloqueo de acceso público para el Bucket S3
resource "aws_s3_bucket_public_access_block" "imagenes_productos_public_access" {
  bucket = aws_s3_bucket.imagenes_productos.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
