terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
    oktapam = {
      source  = "okta/oktapam"
      version = "~> 0.7"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

}

module "test_module" {
  source = "../.." # "git::https://github.com/infrastructurebuilder/okta-enabled-server-tf-module.git"
  group_name = "test"
  aws_region = "us-east-2"
  ami_id = "ami-5bef3202730eb084c" 
  vpc_id = "vpc-d0d63b7a100df0c78"
  subnet_ids = ["subnet-0c78d0d63b7a100df", "subnet-0c78d0d63b7a100df"]
  iam_instance_profile = "ioos_cloud_sandbox_terraform_role"
  instance_type = "t3.2xlarge"
  # root_volume_size = 100
  # data_volume_size = 200
  # data_volume_type = "gp3"
  # canonical_name = "test-server-001"
  # aliases = ["test_admin", "cs_admin", "admin"]
  # additional_security_group_ids = []
  tags = {
    Environment = "test"
    ManagedBy   = "terraform"
  }
  # efs_mount_point = "/mnt/efs/fs1"
}

