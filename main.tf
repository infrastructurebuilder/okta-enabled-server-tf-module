# ---------------------------------------------------------------------------
# OktaPAM lookups — derived from var.group_name using iboktagroup conventions:
#   resource group  = "<group_name>_rg"
#   project         = "<group_name>_rg_login"
#   unix user group = "<group_name>_user"
# ---------------------------------------------------------------------------

data "oktapam_resource_groups" "this" {
  name = "${var.group_name}_rg"
}

data "oktapam_resource_group_projects" "this" {
  resource_group = one(data.oktapam_resource_groups.this.ids)
  name           = "${var.group_name}_rg_login"
}

# Unix gid / group_name live on OktaPAM group *attributes* (separate API
# endpoint not exposed by the Terraform provider), so we fetch them via a
# bundled external data source script.
data "external" "unix_attrs" {
  program = ["${path.module}/scripts/query_unix_attrs.py"]
  query = {
    group_name = "${var.group_name}_user"
  }
}

# groups_and_users snapshot for the update_users.yml playbook, generated at
# plan time from OktaPAM _user/_admin group pairs (base64 JSON in result.b64).
data "external" "groups_and_users" {
  program = ["${path.module}/scripts/gen_groups_and_users.py", "--external"]
  query = {
    groups = "" # empty = all _user/_admin pairs; or e.g. var.group_name
  }
}

locals {
  unix_gid        = tonumber(data.external.unix_attrs.result.gid)
  unix_group_name = data.external.unix_attrs.result.group_name

  # var.tags are applied globally via the provider's default_tags block in the
  # calling root module.  Merge here only for module-local resource Name tags
  # so we never duplicate a key across default_tags and resource tags.
  common_tags = merge({
    Name      = var.canonical_name
  }, var.tags)
}

# ---------------------------------------------------------------------------
# OktaPAM enrollment token
# ---------------------------------------------------------------------------

resource "oktapam_resource_group_server_enrollment_token" "this" {
  resource_group = one(data.oktapam_resource_groups.this.ids)
  project        = one(data.oktapam_resource_group_projects.this.ids)
  description    = "Server enrollment token for ${var.canonical_name}"
}

# ---------------------------------------------------------------------------
# Cloud-init
# ---------------------------------------------------------------------------

data "cloudinit_config" "this" {
  depends_on = [data.external.unix_attrs, data.oktapam_resource_group_projects.this, data.oktapam_resource_groups.this]
  # Gzip keeps the rendered archive under EC2's 16 KB user_data limit; the
  # embedded playbook + groups JSON alone push the plain MIME text past it.
  gzip          = true
  base64_encode = true

  part {
    filename     = "cloud-config.yaml"
    content      = templatefile("${path.module}/templates/cconfig.tftpl", {
      playbook_base64 = filebase64("${path.module}/update_users.yml")
      data_base64     = data.external.groups_and_users.result.b64
    })
  }
  # cloud-init runs user scripts in alphabetical filename order, NOT part
  # order — the numeric prefixes below are what actually sequence them.
  part {
    filename     = "00-install-ssm-agent.sh"
    content_type = "text/x-shellscript"

    content = templatefile("${path.module}/templates/install_ssm_agent.sh.tftpl", {
      aws_region = var.aws_region
    })
  }

  part {
    filename     = "01-enroll-sftd.sh"
    content_type = "text/x-shellscript"

    content = templatefile("${path.module}/templates/cloud_init.sh.tftpl", {
      canonical_name = var.canonical_name
      aliases        = var.aliases
      group_name     = var.group_name
      token          = oktapam_resource_group_server_enrollment_token.this.token
    })
  }

  part {
    filename     = "02-mount-efs.sh"
    content_type = "text/x-shellscript"

    content = templatefile("${path.module}/templates/mount_efs.sh.tftpl", {
      efs_id      = aws_efs_file_system.this.id
      region      = var.aws_region
      mount_point = var.efs_mount_point
    })
  }


  part {
    filename     = "03-mount-volume.sh"
    content_type = "text/x-shellscript"

    content = templatefile("${path.module}/templates/mount_volume.sh.tftpl", {
      mount_point     = "${var.group_name}_data"
      unix_group_name = local.unix_group_name
      unix_gid        = local.unix_gid
    })
  }

  part {
    filename     = "04-install-ansible-and-playbook.sh"
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/install_uv_and_playbook.tftpl", {
    })
  }

  part {
    filename     = "05-install-lustre.sh"
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/install_lustre.sh.tftpl", {
      fsx_dns_name   = local.is_s3_backed_fsx ? module.fsx_with_s3[0].dns_name : ""
      fsx_mount_name = local.is_s3_backed_fsx ? module.fsx_with_s3[0].mount_name : ""
      fsx_mount_dir  = var.fsx_mount_dir
    })
  }
}

# ---------------------------------------------------------------------------
# Security group — attached to the instance; used as NFS source for EFS SG
# ---------------------------------------------------------------------------

resource "aws_security_group" "instance" {
  name        = "${var.canonical_name}-instance-sg"
  description = "Managed SG for ${var.canonical_name}"
  vpc_id      = var.vpc_id

  # sft ssh reaches the server as gateway -> instance, on TWO ports: 4421
  # (sftd's gateway-agent gRPC, used for session setup / on-demand user
  # creation) and then 22 (the bridged SSH session).  Without 4421 the gateway
  # times out during session setup and sft ssh hangs even though sshd:22 is
  # reachable and the server is enrolled.
  dynamic "ingress" {
    for_each = var.gateway_security_group_id == null ? {} : {
      22   = "SSH from OktaPAM gateway"
      4421 = "sftd gateway-agent RPC from OktaPAM gateway"
    }
    content {
      description     = ingress.value
      from_port       = tonumber(ingress.key)
      to_port         = tonumber(ingress.key)
      protocol        = "tcp"
      security_groups = [var.gateway_security_group_id]
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.canonical_name}-instance-sg" })
}

# ---------------------------------------------------------------------------
# EFS
# ---------------------------------------------------------------------------

resource "aws_security_group" "efs" {
  name        = "${var.canonical_name}-efs-sg"
  description = "Allow NFS from ${var.canonical_name} instance to EFS mount targets"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from ${var.canonical_name} instance security group"
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

  tags = merge(local.common_tags, { Name = "${var.canonical_name}-efs-sg" })
}

resource "aws_efs_file_system" "this" {
  creation_token = "${var.canonical_name}-efs"
  encrypted      = true

  tags = merge(local.common_tags, { Name = "${var.canonical_name}-efs" })
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
  user_data_base64            = data.cloudinit_config.this.rendered
  iam_instance_profile        = var.iam_instance_profile

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = var.data_volume_type
    encrypted   = true
  }

  # user_data embeds a point-in-time Okta membership snapshot; ignore drift so
  # membership changes never stop or replace the instance.  Reconcile a running
  # server by re-running update_users.yml on the box (see README), and force a
  # rebuild after intentional cloud-init/template changes with:
  #   tofu apply -replace=aws_instance.this
  lifecycle {
    ignore_changes = [user_data, user_data_base64]
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

  tags = merge(local.common_tags, { Name = "${var.canonical_name}-data" })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}
