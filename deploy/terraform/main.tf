terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    carlos = {
      source = "registry.terraform.io/trytio/carlos"
    }
  }
}

# ─── Providers ─────────────────────────────────────────────
provider "aws" {
  alias  = "us"
  region = var.us_region
}

provider "aws" {
  alias  = "au"
  region = var.au_region
}

# ─── SSH Key ───────────────────────────────────────────────
resource "aws_key_pair" "carlos_us" {
  provider   = aws.us
  key_name   = "carlos-key"
  public_key = file(var.ssh_public_key_path)
}

resource "aws_key_pair" "carlos_au" {
  provider   = aws.au
  key_name   = "carlos-key"
  public_key = file(var.ssh_public_key_path)
}

# ─── S3 presigned URL for binary ──────────────────────────
# The binary is pre-uploaded to S3. Instances download it at boot.

# ─── FCOS AMIs ─────────────────────────────────────────────
data "aws_ami" "fcos_us" {
  provider    = aws.us
  most_recent = true
  owners      = ["125523088429"] # Fedora
  filter {
    name   = "name"
    values = ["fedora-coreos-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "fcos_au" {
  provider    = aws.au
  most_recent = true
  owners      = ["125523088429"]
  filter {
    name   = "name"
    values = ["fedora-coreos-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── US Region ─────────────────────────────────────────────
module "us" {
  source    = "./modules/region"
  providers = { aws = aws.us }

  region_name        = "us"
  vpc_cidr           = "10.10.0.0/16"
  subnet_cidr        = "10.10.1.0/24"
  az                 = "${var.us_region}a"
  ami_id             = data.aws_ami.fcos_us.id
  key_name           = aws_key_pair.carlos_us.key_name
  instance_type      = var.instance_type
  clients_count      = var.clients_per_region
  client_cpu         = var.client_cpu
  client_memory      = var.client_memory
  s3_bucket          = var.carlos_binary_s3_bucket
  s3_key             = var.carlos_binary_s3_key
  include_router     = true
  peer_vpc_cidr      = "10.20.0.0/16"
}

# ─── AU Region ─────────────────────────────────────────────
module "au" {
  source    = "./modules/region"
  providers = { aws = aws.au }

  region_name        = "au"
  vpc_cidr           = "10.20.0.0/16"
  subnet_cidr        = "10.20.1.0/24"
  az                 = "${var.au_region}a"
  ami_id             = data.aws_ami.fcos_au.id
  key_name           = aws_key_pair.carlos_au.key_name
  instance_type      = var.instance_type
  clients_count      = var.clients_per_region
  client_cpu         = var.client_cpu
  client_memory      = var.client_memory
  s3_bucket          = var.carlos_binary_s3_bucket
  s3_key             = var.carlos_binary_s3_key
  include_router     = false
  peer_vpc_cidr      = "10.10.0.0/16"
}

# ─── VPC Peering ───────────────────────────────────────────
resource "aws_vpc_peering_connection" "us_to_au" {
  provider    = aws.us
  vpc_id      = module.us.vpc_id
  peer_vpc_id = module.au.vpc_id
  peer_region = var.au_region
  auto_accept = false
  tags        = { Name = "carlos-us-to-au" }
}

resource "aws_vpc_peering_connection_accepter" "au_accept" {
  provider                  = aws.au
  vpc_peering_connection_id = aws_vpc_peering_connection.us_to_au.id
  auto_accept               = true
  tags                      = { Name = "carlos-us-to-au" }
}

resource "aws_route" "us_to_au" {
  provider                  = aws.us
  route_table_id            = module.us.route_table_id
  destination_cidr_block    = "10.20.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.us_to_au.id
}

resource "aws_route" "au_to_us" {
  provider                  = aws.au
  route_table_id            = module.au.route_table_id
  destination_cidr_block    = "10.10.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.us_to_au.id
}

# ─── Carlos Provider (after infra is up) ──────────────────
provider "carlos" {
  alias   = "us"
  address = "http://${module.us.server_public_ip}:4646"
}

provider "carlos" {
  alias   = "au"
  address = "http://${module.au.server_public_ip}:4646"
}

# ─── Carlos Jobs (US) ─────────────────────────────────────
module "stack_us" {
  source    = "./modules/carlos-stack"
  providers = { carlos = carlos.us }

  stack_name  = "stack-us"
  depends_on  = [module.us]
}

# ─── Carlos Jobs (AU) ─────────────────────────────────────
module "stack_au" {
  source    = "./modules/carlos-stack"
  providers = { carlos = carlos.au }

  stack_name  = "stack-au"
  depends_on  = [module.au]
}
