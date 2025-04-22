# Criando o User Pool no Cognito com CPF como atributo customizado
resource "aws_cognito_user_pool" "user_pool" {
  name = "user-pool"

  # Não vamos usar 'email' ou 'phone_number' como alias, apenas o CPF
  alias_attributes = []  # Não estamos utilizando email ou telefone como alias
  mfa_configuration = "OFF"  # MFA desativada por enquanto

  schema {
    attribute_data_type = "String"
    name                = "cpf"  # O CPF será o atributo customizado
    required            = false  # O CPF não é obrigatório, mas pode ser usado
    mutable             = true   # O CPF pode ser modificado se necessário
  }
}

# IAM Role para a Lambda que será usada para autenticação
resource "aws_iam_role" "lambda_exec_role" {
  name               = "lambda-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Effect    = "Allow"
        Sid       = ""
      },
    ]
  })
}

# Política de permissões para a Lambda acessar o Cognito
resource "aws_iam_role_policy" "lambda_policy" {
  name   = "lambda-policy"
  role   = aws_iam_role.lambda_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "cognito-idp:AdminGetUser"
        Resource = aws_cognito_user_pool.user_pool.arn  # Referência ao pool de usuários
        Effect   = "Allow"
      },
    ]
  })
}

# Criando a função Lambda
resource "aws_lambda_function" "auth_lambda" {
  filename         = "lambda.zip"  # Caminho para o arquivo zip com o código da Lambda
  function_name    = "auth-cognito-lambda"
  role             = aws_iam_role.lambda_exec_role.arn  # A role de execução da Lambda
  handler          = "lambda.lambda_handler"  # Nome da função de entrada da Lambda
  runtime          = "python3.8"
  source_code_hash = filebase64sha256("lambda.zip")  # Garantir que o código está atualizado

  environment {
    variables = {
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.user_pool.id
    }
  }
}

# Criando o API Gateway para invocar a Lambda
resource "aws_api_gateway_rest_api" "api" {
  name        = "auth-api"
  description = "API para autenticação via CPF"
}

resource "aws_api_gateway_resource" "auth" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "auth"
}

resource "aws_api_gateway_method" "auth_post" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.auth.id
  http_method   = "POST"
  authorization = "NONE"  # Não há autenticação adicional aqui, a Lambda valida
}

resource "aws_api_gateway_integration" "auth_integration" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.auth.id
  http_method = aws_api_gateway_method.auth_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.auth_lambda.invoke_arn  # Chamando a Lambda
}

# Permissão para o API Gateway invocar a Lambda
resource "aws_lambda_permission" "allow_api_gateway" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_lambda.function_name
  principal     = "apigateway.amazonaws.com"
}

resource "aws_api_gateway_deployment" "api_deployment" {
  depends_on = [aws_api_gateway_integration.auth_integration]

  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = "prod"  # <-- Esse é o nome do stage que você vai usar
}
