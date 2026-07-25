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

# FSx Lustre outputs — null when the module is used without fsx_s3_bucket.

output "fsx_id" {
  description = "FSx Lustre file system ID."
  value       = one(module.fsx_with_s3[*].fs_id)
}

output "fsx_dns_name" {
  description = "DNS name used to mount the FSx Lustre file system."
  value       = one(module.fsx_with_s3[*].dns_name)
}

output "fsx_mount_name" {
  description = "Lustre mount name (dns@tcp:/mount_name)."
  value       = one(module.fsx_with_s3[*].mount_name)
}

output "fsx_security_group_id" {
  description = "Security group protecting the FSx Lustre ENIs."
  value       = one(module.fsx_with_s3[*].security_group_id)
}
