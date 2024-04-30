terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.47.0"
    }
  }
}

provider "aws" {
  region  = "ap-south-1"
}

resource "aws_lb" "alb" {
  name               = "test-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups = ["sg-00000000"]
  subnets            = ["subnet-1","subnet-2","subnet-3"]

  tags = {
    Environment = "production"
  }
}

resource "aws_lb_target_group" "alb_tg" {
  name        = "tf-lb-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = "vpc-df"
}

resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_tg.arn
  }
}

resource "aws_ecs_cluster" "nodetesttf" {
  name = "node_test_tf"
  setting {
    name = "containerInsights"
    value = "disabled"
  }
  configuration {
    execute_command_configuration {
      logging = "DEFAULT"
    }
  }
#   service_connect_defaults {
#     namespace = aws_ecs_cluster.nodetesttf.arn
#   }
}
resource "aws_ecs_cluster_capacity_providers" "testtfcp" {
  cluster_name = aws_ecs_cluster.nodetesttf.name
  capacity_providers = [ "FARGATE", "FARGATE_SPOT" ]
}

resource "aws_ecs_task_definition" "nodetesttftd" {
  family = "nodetesttftd"
  requires_compatibilities = [ "FARGATE" ]
  cpu = 1024
  memory = 3072
  execution_role_arn = "arn:aws:iam::xxxxxxxxxx:role/ecsTaskExecutionRole"
  network_mode = "awsvpc"
  runtime_platform {
    cpu_architecture = "X86_64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode(
    [
        {
            "name": "testtfimage",
            "image": "xxxxxxxxx.dkr.ecr.ap-south-1.amazonaws.com/test1node:latest",
            "memory": 1946,
            "memoryReservation": 1536,
            "portMappings": [
                {
                    containerPort: 8000,
                    "name": "defaulttf"
                }
            ],
            "healthCheck":  {
                "command": [ "CMD-SHELL", "curl -f http://localhost:8000/health || exit 1" ],
                "timeout": 5,
                "retries": 3,
                "interval": 30
            },
            "logConfiguration": {
                "logDriver": "awslogs",
                "options": {
                    "awslogs-create-group": "true",
                    "awslogs-group": "/ecs/test2node",
                    "awslogs-region": "ap-south-1",
                    "awslogs-stream-prefix": "ecs"
                }
            },
            "essential": true
        }
    ])
}

resource "aws_ecs_service" "testtfservice" {
  cluster = aws_ecs_cluster.nodetesttf.arn
  name = "testtfservice"
  task_definition = aws_ecs_task_definition.nodetesttftd.arn
  desired_count = 1
  scheduling_strategy = "REPLICA"
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base = 0
    weight = 1
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.alb_tg.arn
    container_name = "testtfimage"
    container_port = 8000
  }
  network_configuration {
    assign_public_ip = true
    subnets = [ "subnet1","subnet-2","subnet-3" ]
    security_groups = [ "sg-df" ]
  }
  platform_version = "LATEST"
  deployment_maximum_percent = 200
  deployment_minimum_healthy_percent = 100
  deployment_circuit_breaker {
    enable = true
    rollback = true
  }
  deployment_controller {
    type = "ECS"
  }
  service_connect_configuration {
    enabled = false
  }
  enable_ecs_managed_tags = true
  depends_on = [ aws_ecs_cluster.nodetesttf, aws_ecs_task_definition.nodetesttftd, aws_lb_listener.front_end ]
}

resource "aws_appautoscaling_target" "testtfast" {
  max_capacity = 2
  min_capacity = 1
  resource_id = "service/${aws_ecs_cluster.nodetesttf.name}/${aws_ecs_service.testtfservice.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace = "ecs"
  depends_on = [ aws_ecs_service.testtfservice ]
}

resource "aws_appautoscaling_policy" "astpolicy" {
  name = "scale-up"
  policy_type = "TargetTrackingScaling"
  resource_id = aws_appautoscaling_target.testtfast.resource_id
  scalable_dimension = aws_appautoscaling_target.testtfast.scalable_dimension
  service_namespace = aws_appautoscaling_target.testtfast.service_namespace
  target_tracking_scaling_policy_configuration {
    target_value = 80
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_route53_record" "api" {
  zone_id = "xxxxxxxxxx"
  name = "api.sthrtshngf.rtg"
  type = "CNAME"
  ttl = 300
  records = [ aws_lb.alb.dns_name ]
  depends_on = [ aws_lb.alb ]
}
