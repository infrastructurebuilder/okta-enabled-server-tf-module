# ---------------------------------------------------------------------------
# Required
# ---------------------------------------------------------------------------

variable "group_name" {
  description = "Short identifier for the group (e.g. \"gsoc\"). Drives resource names, OktaPAM labels, and EFS/EBS tags."
  type        = string
}

variable "ami_id" {
  description = "AMI ID to use for the EC2 instance."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID in which to create all resources."
  type        = string
}

variable "subnet_ids" {
  description = "List of private subnet IDs. The instance lands in subnet_ids[0]; EFS mount targets are created in every subnet."
  type        = list(string)
}

variable "iam_instance_profile" {
  description = "Name of the IAM instance profile to attach to the instance."
  type        = string
  default     = "ioos_cloud_sandbox_terraform_role"
}

variable "aws_region" {
  description = "AWS region (used inside the EFS mount cloud-init script)."
  type        = string
  default     = "us-east-2"
}

# oktapam_resource_group_id, oktapam_project_id, unix_group_name, and unix_gid
# are resolved internally via OktaPAM data sources and the bundled
# scripts/query_unix_attrs.py external data source, keyed off var.group_name.

# ---------------------------------------------------------------------------
# Optional / with defaults
# ---------------------------------------------------------------------------

variable "canonical_name" {
  description = "OktaPAM canonical name for the server."
  type        = string
}

variable "aliases" {
  description = "OktaPAM AltNames for the server."
  type        = list(string)
  default     = []
}

variable "additional_security_group_ids" {
  description = "Security group IDs to attach to the EC2 instance in addition to the module-managed instance SG."
  type        = list(string)
  default     = []
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.2xlarge"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB."
  type        = number
  default     = 100
}

variable "data_volume_size" {
  description = "EBS data volume size in GB."
  type        = number
  default     = 200
}

variable "data_volume_type" {
  description = "EBS volume type for root and data volumes (gp3, gp2, io1, etc.)."
  type        = string
  default     = "gp3"
}

variable "efs_mount_point" {
  description = "Path at which the EFS share is mounted on the instance."
  type        = string
  default     = "/mnt/efs/fs1"
}

variable "tags" {
  description = "Additional tags to merge onto every resource. Do NOT include tags already applied via the provider's default_tags block."
  type        = map(string)
  default     = {}
}
