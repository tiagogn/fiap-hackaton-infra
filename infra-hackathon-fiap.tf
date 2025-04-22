provider "aws" {
  region     = "us-east-1"
  access_key = ""
  secret_key = ""
}

######################
# CloudWatch Logs
######################

resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/fiap-hackaton"
  retention_in_days = 7
}

######################
# Infraestrutura Base
######################

data "aws_availability_zones" "available" {}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "main-vpc"
  }
}

resource "aws_vpc_dhcp_options" "default" {
  domain_name_servers = ["AmazonProvidedDNS"]
}

resource "aws_vpc_dhcp_options_association" "default" {
  vpc_id          = aws_vpc.main.id
  dhcp_options_id = aws_vpc_dhcp_options.default.id
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main-igw"
  }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = {
    Name = "main-rt"
  }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-${count.index + 1}"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.main.id
}

######################
# Load Balancer
######################

resource "aws_lb" "ecs_alb" {
  name               = "ecs-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "controller_tg" {
  name        = "controller-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/controller/actuator/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ecs_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "controller_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.controller_tg.arn
  }
  condition {
    path_pattern {
      values = [
        "/controller/v1/upload*",
        "/controller/v1/download*",
        "/controller/v1/list*",
        "/controller/actuator/health"
      ]
    }
  }
}

######################
# Security Groups
######################

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP/HTTPS for ALB"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-sg"
  }
}

resource "aws_security_group" "ecs_sg" {
  name        = "ecs-sg"
  description = "Allow HTTP"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-sg"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "rds-sg"
  description = "Allow Postgres access"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

######################
# Database
######################

resource "aws_db_subnet_group" "main" {
  name       = "main-db-subnet-group"
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_db_instance" "main" {
  identifier              = "my-db-instance"
  engine                  = "postgres"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"
  db_name                 = "videos"
  username                = "dbuser"
  password                = "password"
  publicly_accessible     = true
  multi_az                = false
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  db_subnet_group_name    = aws_db_subnet_group.main.name
  skip_final_snapshot     = true
}

######################
# S3, SQS, SES
######################

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "videos" {
  bucket        = "videos-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_sqs_queue" "video_queue" {
  name = "video-processing-queue"
}

resource "aws_ses_email_identity" "notification_email" {
  email = "roseanecosta88@gmail.com"
}

######################
# ECS Cluster, IAM Roles & Policies
######################

resource "aws_ecs_cluster" "main" {
  name = "my-ecs-cluster"
}

resource "aws_iam_role" "ecs_execution_role" {
  name = "ecsTaskExecutionRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "ecs_app_policy" {
  name = "ecsAppPolicy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["s3:*"], Resource = "*" },
      { Effect = "Allow", Action = ["sqs:*"], Resource = "*" },
      { Effect = "Allow", Action = ["ses:SendEmail", "ses:SendRawEmail"], Resource = "*" }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_app_policy_attachment" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = aws_iam_policy.ecs_app_policy.arn
}

######################
# ECS Task Definitions
######################

resource "aws_ecs_task_definition" "fiap_hackaton_controller" {
  family                   = "fiap-hackaton-controller"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  container_definitions = jsonencode([{
    name      = "fiap-hackaton-controller",
    image     = "hackathonfiap/fiap-hackaton-controller:latest",
    cpu       = 256,
    memory    = 512,
    essential = true,
    portMappings = [{ containerPort = 8080, hostPort = 8080 }],
    environment = [
      { name = "SPRING_PROFILES_ACTIVE", value = "prd" },
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_NAME", value = aws_db_instance.main.db_name },
      { name = "DB_USER", value = aws_db_instance.main.username },
      { name = "DB_PASSWORD", value = "password" },
      { name = "AWS_REGION", value = "us-east-1" },
      { name = "AWS_S3_BUCKET", value = aws_s3_bucket.videos.bucket },
      { name = "AWS_SQS_QUEUE_NAME", value = aws_sqs_queue.video_queue.name },
      { name = "AWS_SQS_ENDPOINT", value = "https://sqs.us-east-1.amazonaws.com" },
      { name = "AWS_S3_ENDPOINT", value = "https://s3.amazonaws.com"},
      { name = "AWS_SES_EMAIL_FROM", value = aws_ses_email_identity.notification_email.email },
      { name = "APP_DOWNLOAD_URL", value = "http://${aws_lb.ecs_alb.dns_name}/controller/v1/download" },
      { name = "AWS_ACCESS_KEY_ID", value = "" },
      { name = "AWS_SECRET_ACCESS_KEY", value = "" }
    ],
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs_log_group.name,
        awslogs-region        = "us-east-1",
        awslogs-stream-prefix = "controller"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "fiap_hackaton_processor" {
  family                   = "fiap-hackaton-processor"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "fiap-hackaton-processor",
    image     = "tiagogn/fiap-hackaton-processor:1.0.0",
    cpu       = 256,
    memory    = 512,
    essential = true,
    portMappings = [
      { containerPort = 8081, hostPort = 8081 }
    ],
    environment = [
      { name = "SPRING_PROFILES_ACTIVE", value = "prd" },
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_NAME", value = aws_db_instance.main.db_name },
      { name = "DB_USER", value = aws_db_instance.main.username },
      { name = "DB_PASSWORD", value = "password" },
      { name = "AWS_REGION", value = "us-east-1" },
      { name = "AWS_S3_BUCKET", value = aws_s3_bucket.videos.bucket },
      { name = "AWS_SQS_QUEUE_NAME", value = aws_sqs_queue.video_queue.name },
      { name = "AWS_S3_ENDPOINT", value = "https://s3.amazonaws.com"},
      { name = "AWS_SQS_ENDPOINT", value = "https://sqs.us-east-1.amazonaws.com"},
      { name = "AWS_VIDEO_BUCKET", value = aws_s3_bucket.videos.bucket },
      { name = "AWS_SQS_QUEUE_NAME", value = aws_sqs_queue.video_queue.name },
      { name = "AWS_SES_EMAIL_FROM", value = aws_ses_email_identity.notification_email.email },
      { name = "AWS_SES_ENDPOINT", value = ""},
      { name = "APP_DOWNLOAD_URL", value = "http://${aws_lb.ecs_alb.dns_name}/controller/v1/download" },
      { name = "AWS_ACCESS_KEY_ID", value = "" },
      { name = "AWS_SECRET_ACCESS_KEY", value = "" }
    ],
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs_log_group.name,
        awslogs-region        = "us-east-1",
        awslogs-stream-prefix = "processor"
      }
    }
  }])
}

######################
# ECS Services
######################

resource "aws_ecs_service" "fiap_hackaton_controller_service" {
  name            = "fiap-hackaton-controller-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.fiap_hackaton_controller.arn
  launch_type     = "FARGATE"
  desired_count   = 1
  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.controller_tg.arn
    container_name   = "fiap-hackaton-controller"
    container_port   = 8080
  }
}

resource "aws_ecs_service" "fiap_hackaton_processor_service" {
  name            = "fiap-hackaton-processor-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.fiap_hackaton_processor.arn
  launch_type     = "FARGATE"
  desired_count   = 1
  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_sg.id]
    assign_public_ip = true
  }
}

output "controller_base_url" {
  value = "http://${aws_lb.ecs_alb.dns_name}/controller"
}