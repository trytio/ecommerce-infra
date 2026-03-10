# ─── VPC ───────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "carlos-${var.region_name}" }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "carlos-${var.region_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = true
  tags                    = { Name = "carlos-${var.region_name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "carlos-${var.region_name}-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─── Security Group ───────────────────────────────────────
resource "aws_security_group" "carlos" {
  name        = "carlos-${var.region_name}-sg"
  description = "Carlos cluster — ${var.region_name}"
  vpc_id      = aws_vpc.main.id

  # SSH
  ingress { from_port = 22;    to_port = 22;    protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  # Carlos API + client + heartbeat
  ingress { from_port = 4646;  to_port = 4648;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  # VRE TCP + mTLS
  ingress { from_port = 5647;  to_port = 7647;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  # WireGuard
  ingress { from_port = 51820; to_port = 51820; protocol = "udp"; cidr_blocks = ["0.0.0.0/0"] }
  # LB ports (frontend 8080, api 8081)
  ingress { from_port = 8080;  to_port = 8082;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  # Router mgmt
  ingress { from_port = 8443;  to_port = 8443;  protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  # All intra-VPC + cross-region VPC peering (10.0.0.0/8 covers both 10.10 and 10.20)
  ingress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["10.0.0.0/8"] }
  # All outbound
  egress  { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }

  tags = { Name = "carlos-${var.region_name}-sg" }
}

# ─── IAM Role (S3 read for binary download) ───────────────
resource "aws_iam_role" "carlos" {
  name = "carlos-${var.region_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "s3_read" {
  name = "carlos-s3-read"
  role = aws_iam_role.carlos.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "arn:aws:s3:::${var.s3_bucket}/${var.s3_key}"
    }]
  })
}

resource "aws_iam_instance_profile" "carlos" {
  name = "carlos-${var.region_name}-profile"
  role = aws_iam_role.carlos.name
}

# ─── Ignition user data builder ───────────────────────────
locals {
  server_private_ip = cidrhost(var.subnet_cidr, 16)

  base_ignition = {
    ignition = { version = "3.4.0" }
    storage = {
      directories = [
        { path = "/opt/carlos/bin", mode = 493 },
        { path = "/var/lib/carlos", mode = 488 },
        { path = "/var/lib/carlos/volumes", mode = 488 },
      ]
      files = [
        {
          path = "/etc/sysctl.d/90-carlos.conf"
          mode = 420
          contents = { source = "data:,net.ipv4.ip_forward%3D1%0Avm.overcommit_memory%3D1%0Afs.file-max%3D1048576%0Anet.core.somaxconn%3D65535%0A" }
        },
      ]
    }
  }

  # Systemd units common to all roles
  podman_override = {
    name = "podman.service"
    dropins = [{
      name     = "override.conf"
      contents = "[Service]\nKillMode=process\nType=exec\nTimeoutStopSec=30\n"
    }]
  }
}

# ─── Server ────────────────────────────────────────────────
resource "aws_instance" "server" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.carlos.id]
  iam_instance_profile   = aws_iam_instance_profile.carlos.name
  private_ip             = local.server_private_ip

  user_data = jsonencode({
    ignition = { version = "3.4.0" }
    storage = {
      directories = local.base_ignition.storage.directories
      files = concat(local.base_ignition.storage.files, [
        {
          path = "/opt/carlos/bin/bootstrap.sh"
          mode = 493
          contents = {
            source = "data:text/plain;charset=utf-8;base64,${base64encode(templatefile("${path.module}/templates/bootstrap.sh", {
              role          = "server"
              s3_bucket     = var.s3_bucket
              s3_key        = var.s3_key
              region_name   = var.region_name
              server_ip     = local.server_private_ip
              client_cpu    = var.client_cpu
              client_memory = var.client_memory
              node_index    = 0
            }))}"
          }
        },
      ])
    }
    systemd = {
      units = [
        { name = "podman.socket", enabled = true },
        local.podman_override,
        {
          name    = "carlos-server.service"
          enabled = true
          contents = <<-UNIT
            [Unit]
            Description=Carlos Server
            After=network-online.target
            Wants=network-online.target
            [Service]
            Type=exec
            ExecStartPre=/opt/carlos/bin/bootstrap.sh
            ExecStart=/opt/carlos/bin/carlos server --bind 0.0.0.0:4646 --data-dir /var/lib/carlos
            Restart=always
            RestartSec=5
            Environment=RUST_LOG=carlos=info
            [Install]
            WantedBy=multi-user.target
          UNIT
        },
      ]
    }
  })

  root_block_device { volume_size = 20; volume_type = "gp3" }
  tags = { Name = "carlos-server-${var.region_name}" }
}

# ─── Clients ──────────────────────────────────────────────
resource "aws_instance" "client" {
  count                  = var.clients_count
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.carlos.id]
  iam_instance_profile   = aws_iam_instance_profile.carlos.name

  user_data = jsonencode({
    ignition = { version = "3.4.0" }
    storage = {
      directories = local.base_ignition.storage.directories
      files = concat(local.base_ignition.storage.files, [
        {
          path = "/opt/carlos/bin/bootstrap.sh"
          mode = 493
          contents = {
            source = "data:text/plain;charset=utf-8;base64,${base64encode(templatefile("${path.module}/templates/bootstrap.sh", {
              role          = "client"
              s3_bucket     = var.s3_bucket
              s3_key        = var.s3_key
              region_name   = var.region_name
              server_ip     = local.server_private_ip
              client_cpu    = var.client_cpu
              client_memory = var.client_memory
              node_index    = count.index + 1
            }))}"
          }
        },
      ])
    }
    systemd = {
      units = [
        { name = "podman.socket", enabled = true },
        local.podman_override,
        {
          name    = "carlos-client.service"
          enabled = true
          contents = <<-UNIT
            [Unit]
            Description=Carlos Client
            After=network-online.target podman.socket
            Wants=network-online.target podman.socket
            [Service]
            Type=exec
            ExecStartPre=/opt/carlos/bin/bootstrap.sh
            ExecStart=/opt/carlos/bin/carlos client --server ${local.server_private_ip}:4646 --cpu ${var.client_cpu} --memory ${var.client_memory} --labels region=${var.region_name},node=${count.index + 1} --data-dir /var/lib/carlos
            Restart=always
            RestartSec=5
            Environment=RUST_LOG=carlos=info
            Environment=CONTAINER_HOST=unix:///run/podman/podman.sock
            [Install]
            WantedBy=multi-user.target
          UNIT
        },
        {
          name    = "iptables-forward.service"
          enabled = true
          contents = <<-UNIT
            [Unit]
            Description=Set iptables FORWARD ACCEPT for podman port forwarding
            After=network-online.target
            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/sbin/iptables -P FORWARD ACCEPT
            [Install]
            WantedBy=multi-user.target
          UNIT
        },
        {
          name    = "selinux-permissive.service"
          enabled = true
          contents = <<-UNIT
            [Unit]
            Description=Set SELinux to Permissive
            Before=carlos-client.service
            [Service]
            Type=oneshot
            RemainAfterExit=yes
            ExecStart=/usr/sbin/setenforce 0
            [Install]
            WantedBy=multi-user.target
          UNIT
        },
      ]
    }
  })

  root_block_device { volume_size = 20; volume_type = "gp3" }
  tags = { Name = "carlos-client-${var.region_name}-${count.index + 1}" }
}

# ─── Router (US only) ─────────────────────────────────────
resource "aws_instance" "router" {
  count                  = var.include_router ? 1 : 0
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.carlos.id]
  iam_instance_profile   = aws_iam_instance_profile.carlos.name

  user_data = jsonencode({
    ignition = { version = "3.4.0" }
    storage = {
      directories = local.base_ignition.storage.directories
      files = concat(local.base_ignition.storage.files, [
        {
          path = "/opt/carlos/bin/bootstrap.sh"
          mode = 493
          contents = {
            source = "data:text/plain;charset=utf-8;base64,${base64encode(templatefile("${path.module}/templates/bootstrap.sh", {
              role          = "router"
              s3_bucket     = var.s3_bucket
              s3_key        = var.s3_key
              region_name   = var.region_name
              server_ip     = local.server_private_ip
              client_cpu    = var.client_cpu
              client_memory = var.client_memory
              node_index    = 0
            }))}"
          }
        },
      ])
    }
    systemd = {
      units = [
        {
          name    = "carlos-router.service"
          enabled = true
          contents = <<-UNIT
            [Unit]
            Description=Carlos Router
            After=network-online.target
            Wants=network-online.target
            [Service]
            Type=exec
            ExecStartPre=/opt/carlos/bin/bootstrap.sh
            ExecStart=/opt/carlos/bin/carlos router --bind 0.0.0.0:8443 --proxy-bind 0.0.0.0:8080
            Restart=always
            RestartSec=5
            Environment=RUST_LOG=carlos=info
            [Install]
            WantedBy=multi-user.target
          UNIT
        },
      ]
    }
  })

  root_block_device { volume_size = 20; volume_type = "gp3" }
  tags = { Name = "carlos-router" }
}
