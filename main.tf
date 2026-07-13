locals {
  canonical_name = coalesce(var.canonical_name, "${var.group_name}-server-001")

  # var.tags are applied globally via the provider's default_tags block in the
  # calling root module.  Merge here only for module-local resource Name tags
  # so we never duplicate a key across default_tags and resource tags.
  common_tags = merge({
    Name      = "${var.group_name} Server"
    ManagedBy = "terraform"
  }, var.tags)
}

# ---------------------------------------------------------------------------
# OktaPAM enrollment token
# ---------------------------------------------------------------------------

resource "oktapam_resource_group_server_enrollment_token" "this" {
  resource_group = var.oktapam_resource_group_id
  project        = var.oktapam_project_id
  description    = "Server enrollment token for ${var.group_name}"
}

# ---------------------------------------------------------------------------
# Cloud-init
# ---------------------------------------------------------------------------

data "cloudinit_config" "this" {
  gzip          = false
  base64_encode = false

  part {
    content_type = "text/x-shellscript"

    content = templatefile("${path.module}/templates/cloud_init.sh.tftpl", {
      canonical_name = local.canonical_name
      aliases        = var.aliases
      group_name     = var.group_name
      token          = oktapam_resource_group_server_enrollment_token.this.token
    })
  }

  part {
    filename     = "mount-efs.sh"
    content_type = "text/x-shellscript"

    content = templatefile("${path.module}/templates/mount_efs.sh.tftpl", {
      efs_id      = aws_efs_file_system.this.id
      region      = var.aws_region
      mount_point = var.efs_mount_point
    })
  }

  part {
    filename     = "mount-volume.sh"
    content_type = "text/x-shellscript"

    content = templatefile("${path.module}/templates/mount_volume.sh.tftpl", {
      mount_point     = "${var.group_name}_data"
      unix_group_name = var.unix_group_name
      unix_gid        = var.unix_gid
    })
  }
}

# ---------------------------------------------------------------------------
# Security group — attached to the instance; used as NFS source for EFS SG
# ---------------------------------------------------------------------------

resource "aws_security_group" "instance" {
  name        = "${var.group_name}-instance-sg"
  description = "Managed SG for ${var.group_name} instance"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.group_name}-instance-sg" })
}

# ---------------------------------------------------------------------------
# EFS
# ---------------------------------------------------------------------------

resource "aws_security_group" "efs" {
  name        = "${var.group_name}-efs-sg"
  description = "Allow NFS from ${var.group_name} instance to EFS mount targets"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from ${var.group_name} instance security group"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.instance.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.group_name}-efs-sg" })
}

resource "aws_efs_file_system" "this" {
  creation_token = "${var.group_name}-efs"
  encrypted      = true

  tags = merge(local.common_tags, { Name = "${var.group_name}-efs" })
}

# One mount target per private subnet so the instance can reach EFS regardless
# of which AZ it lands in.
resource "aws_efs_mount_target" "this" {
  for_each = toset(var.subnet_ids)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------

resource "aws_instance" "this" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_ids[0]

  vpc_security_group_ids = concat(
    [aws_security_group.instance.id],
    var.additional_security_group_ids,
  )

  associate_public_ip_address = false
  user_data                   = data.cloudinit_config.this.rendered
  iam_instance_profile        = var.iam_instance_profile

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = var.data_volume_type
    encrypted   = true
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# EBS data volume
# ---------------------------------------------------------------------------

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.this.availability_zone
  size              = var.data_volume_size
  type              = var.data_volume_type
  encrypted         = true

  tags = merge(local.common_tags, { Name = "${var.group_name}-data" })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}
