provider "aws" {
  region = var.region
}

resource "aws_security_group" "alb-sec-group" {
  name = "alb-sec-group"
  description = "Security Group for the ELB (ALB)"
  egress {
    from_port = 0
    protocol = "-1"
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 80
    protocol = "tcp"
    to_port = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 443
    protocol = "tcp"
    to_port = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "asg_sec_group" {
  name = "asg_sec_group"
  description = "Security Group for the ASG"
  tags = {
    name = "name"
  }
  egress {
    from_port = 0
    protocol = "-1" 
    to_port = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 80
    protocol = "tcp"
    to_port = 80
    security_groups = [aws_security_group.alb-sec-group.id] 
  }
}


resource "aws_launch_configuration" "ec2_template" {
  image_id = var.image_id
  instance_type = var.flavor
  user_data = <<-EOF
            #!/bin/bash
            yum install httpd php php-mysql -y
            cd /var/www/html
            wget https://wordpress.org/latest.tar.gz
            tar -xzf latest.tar.gz
            cp -r wordpress/* /var/www/html/
            rm -rf wordpress
            rm -rf latest.tar.gz
            chmod -R 755 wp-content
            chown -R apache:apache wp-content
            sudo cp wp-config-sample.php wp-config.php
            sudo echo "

            # BEGIN WordPress
            <IfModule mod_rewrite.c>
            RewriteEngine On
            RewriteBase /
            RewriteRule ^index\.php$ - [L]
            RewriteCond %{REQUEST_FILENAME} !-f
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteRule . /index.php [L]
            </IfModule>
            # END WordPress

            " > .htaccess
            chkconfig httpd on
            EOF
  security_groups = [aws_security_group.asg_sec_group.id]

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}


resource "aws_autoscaling_group" "Practice_ASG" {
  max_size = 5
  min_size = 1
  launch_configuration = aws_launch_configuration.ec2_template.name
  health_check_grace_period = 300 

  health_check_type = "ELB" 

  vpc_zone_identifier = data.aws_subnet_ids.default.ids 

  target_group_arns = [aws_lb_target_group.asg.arn]

  tag {
    key = "name"
    propagate_at_launch = false
    value = "Practice_ASG"
  }
  lifecycle {
  create_before_destroy = true
  }
}

resource "aws_lb" "ELB" {
  name               = "terraform-asg-example"
  load_balancer_type = "application"

  subnets  = data.aws_subnet_ids.default.ids
  security_groups = [aws_security_group.alb-sec-group.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.ELB.arn 
  port = 80
  protocol = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}


resource "aws_lb_target_group" "asg" {
  name = "asg-example"
  port = var.ec2_instance_port
  protocol = "HTTP"
  vpc_id = data.aws_vpc.default.id

  health_check {
    path = "/"
    protocol = "HTTP"
    matcher = "200"
    interval = 15
    timeout = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100

  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
  condition {
    path_pattern {
      values = ["*"]
    }
  }
}

resource "aws_autoscaling_policy" "agents-scale-up" {
    name = "agents-scale-up"
    scaling_adjustment = 1
    adjustment_type = "ChangeInCapacity"
    cooldown = 300
    autoscaling_group_name = "${aws_autoscaling_group.agents.name}"
}

resource "aws_autoscaling_policy" "agents-scale-down" {
    name = "agents-scale-down"
    scaling_adjustment = -1
    adjustment_type = "ChangeInCapacity"
    cooldown = 300
    autoscaling_group_name = "${aws_autoscaling_group.agents.name}"
}

resource "aws_cloudwatch_metric_alarm" "cpu-high" {
    alarm_name = "cpu-util-high-agents"
    comparison_operator = "GreaterThanOrEqualToThreshold"
    evaluation_periods = "2"
    metric_name = "CPUUtilization"
    namespace = "System/Linux"
    period = "300"
    statistic = "Average"
    threshold = "70"
    alarm_description = "This metric monitors ec2 cpu for high utilization on agent hosts"
    alarm_actions = [
        "${aws_autoscaling_policy.agents-scale-up.arn}"
    ]
    dimensions = {
        AutoScalingGroupName = "${aws_autoscaling_group.agents.name}"
    }
}

resource "aws_cloudwatch_metric_alarm" "cpu-low" {
    alarm_name = "cpu-util-low-agents"
    comparison_operator = "LessThanOrEqualToThreshold"
    evaluation_periods = "2"
    metric_name = "CPUUtilization"
    namespace = "System/Linux"
    period = "300"
    statistic = "Average"
    threshold = "40"
    alarm_description = "This metric monitors ec2 cpu for low utilization on agent hosts"
    alarm_actions = [
        "${aws_autoscaling_policy.agents-scale-down.arn}"
    ]
    dimensions = {
        AutoScalingGroupName = "${aws_autoscaling_group.agents.name}"
    }
}