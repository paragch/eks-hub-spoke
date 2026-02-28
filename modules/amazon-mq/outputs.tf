output "broker_id" {
  description = "Amazon MQ broker ID"
  value       = aws_mq_broker.main.id
}

output "broker_arn" {
  description = "Amazon MQ broker ARN"
  value       = aws_mq_broker.main.arn
}

# AMQP+SSL endpoints — one per broker instance (2 for ACTIVE_STANDBY_MULTI_AZ).
# Use the failover URL for HA clients:
#   failover:(amqp+ssl://host1:5671,amqp+ssl://host2:5671)?maxReconnectAttempts=10
output "amqp_ssl_endpoints" {
  description = "AMQP+SSL endpoints (port 5671) — one per broker instance. Use the failover URL in client configuration."
  # instances[*].endpoints[0] is always the amqp+ssl:// endpoint for ActiveMQ
  value = [for inst in aws_mq_broker.main.instances : inst.endpoints[0]]
}

output "amqp_failover_url" {
  description = "Ready-to-use ActiveMQ failover URL for AMQP+SSL clients (port 5671)"
  value       = "failover:(${join(",", [for inst in aws_mq_broker.main.instances : inst.endpoints[0]])})?maxReconnectAttempts=10"
}

output "openwire_ssl_endpoints" {
  description = "OpenWire+SSL endpoints (port 61617) for Java/JMS clients"
  value       = [for inst in aws_mq_broker.main.instances : inst.endpoints[1]]
}

output "console_url" {
  description = "ActiveMQ web console URL (accessible from within the VPC only)"
  value       = aws_mq_broker.main.instances[0].console_url
}

output "security_group_id" {
  description = "Security group ID attached to the Amazon MQ brokers"
  value       = aws_security_group.mq.id
}
