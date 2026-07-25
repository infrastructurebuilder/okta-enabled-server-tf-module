locals {
  is_s3_backed_fsx = var.fsx_s3_bucket != null
}

# Every CIDR associated with the VPC, so Lustre's port 988 is open to clients
# regardless of which (primary or secondary) VPC range they live in.
data "aws_vpc" "fsx" {
  count = local.is_s3_backed_fsx ? 1 : 0
  id    = var.vpc_id
}

module "fsx_with_s3" {
  # The count meta-argument controls whether this module runs
  count  = local.is_s3_backed_fsx ? 1 : 0

  # Point to your Git repository
  source = "git::https://github.com/infrastructurebuilder/aws-fsx-lustre-s3backed-tf-module.git"

  # Pass the variable to the module's expected input
  s3_bucket_name   = var.fsx_s3_bucket
  s3_import_prefix = var.fsx_s3_import_prefix
  s3_export_prefix = var.fsx_s3_export_prefix

  # Include any other variables your module requires
  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids
  allowed_cidr_blocks = data.aws_vpc.fsx[0].cidr_block_associations[*].cidr_block
}

