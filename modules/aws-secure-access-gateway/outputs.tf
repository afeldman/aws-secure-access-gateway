# Outputs for the AWS Secure Access Gateway module

output "gateway_instance_id" {
  description = "The ID of the EC2 instance running the access gateway."
  value       = aws_instance.gateway.id
}

output "connection_command" {
  description = "Example command to start an SSM session to the gateway instance."
  value       = "aws ssm start-session --target ${aws_instance.gateway.id}"
}

output "kubeconfig_command" {
  description = "Instructions on how to configure kubectl on the gateway instance."
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${var.eks_cluster_name}"
}

output "service_endpoint" {
  description = "The local endpoint on the gateway that developers connect to for mTLS."
  value       = "localhost:10000" # As configured in envoy-config.yaml.tpl
}

output "audit_logs_url" {
  description = "A pre-configured URL to view the audit logs for this gateway in CloudWatch Logs Insights."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#logsV2:log-groups/log-group/${replace(replace(local.log_group_name, ":", "%3A"), "/", "$252F")}" # URL-encoded log group
}
