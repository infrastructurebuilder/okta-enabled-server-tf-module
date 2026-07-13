output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Private IP address of the EC2 instance."
  value       = aws_instance.this.private_ip
}

output "availability_zone" {
  description = "Availability zone the instance was launched in."
  value       = aws_instance.this.availability_zone
}

output "efs_id" {
  description = "EFS file system ID."
  value       = aws_efs_file_system.this.id
}

output "ebs_volume_id" {
  description = "EBS data volume ID."
  value       = aws_ebs_volume.data.id
}

output "instance_security_group_id" {
  description = "ID of the module-managed instance security group."
  value       = aws_security_group.instance.id
}

output "enrollment_token" {
  description = "OktaPAM server enrollment token written into cloud-init."
  value       = oktapam_resource_group_server_enrollment_token.this.token
  sensitive   = true
}
