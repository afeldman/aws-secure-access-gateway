# Outputs for the Honeytrap EC2 Submodule

output "honeytrap_instance_id" {
  description = "The ID of the EC2 instance running Honeytrap."
  value       = aws_instance.honeytrap.id
}

output "honeytrap_private_ip" {
  description = "The private IP address of the Honeytrap instance."
  value       = aws_instance.honeytrap.private_ip
}

output "honeytrap_connection_command" {
  description = "Example command to start an SSM session to the Honeytrap instance (for monitoring/debugging)."
  value       = "aws ssm start-session --target ${aws_instance.honeytrap.id} --region ${var.region}"
}

output "honeytrap_security_group_id" {
  description = "The security group ID for the Honeytrap instance."
  value       = aws_security_group.honeytrap.id
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group receiving Honeytrap logs."
  value       = aws_cloudwatch_log_group.honeytrap.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group for Honeytrap."
  value       = aws_cloudwatch_log_group.honeytrap.arn
}

output "honeytrap_logs_insights_url" {
  description = "A pre-configured URL to view Honeytrap logs in CloudWatch Logs Insights."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#logsV2:logs-insights$3FqueryDetail$3D~(end~0~start~-3600~timeType~'RELATIVE~unit~'seconds~editorString~'fields*20*40timestamp*2c*20*40message*0afilter*20*40message*20like*20*2fconnection*2f~source~(~'${replace(aws_cloudwatch_log_group.honeytrap.name, "/", "$252F")})"
}

output "alarm_activity_arn" {
  description = "ARN of the CloudWatch alarm for Honeytrap activity detection."
  value       = aws_cloudwatch_metric_alarm.honeytrap_activity.arn
}

output "alarm_auth_success_arn" {
  description = "ARN of the CloudWatch alarm for Honeytrap authentication validation (critical)."
  value       = aws_cloudwatch_metric_alarm.honeytrap_auth_success.arn
}

output "honeytrap_role_arn" {
  description = "ARN of the IAM role for the Honeytrap instance."
  value       = aws_iam_role.honeytrap.arn
}

output "honeytrap_role_name" {
  description = "Name of the IAM role for the Honeytrap instance."
  value       = aws_iam_role.honeytrap.name
}
