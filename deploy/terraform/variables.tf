variable "ssh_public_key_path" {
  description = "Path to SSH public key for EC2 instances"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "carlos_binary_s3_bucket" {
  description = "S3 bucket containing the Carlos binary"
  type        = string
  default     = "carlos-os-artifacts"
}

variable "carlos_binary_s3_key" {
  description = "S3 key for the Carlos binary"
  type        = string
  default     = "carlos-x86_64"
}

variable "instance_type" {
  description = "EC2 instance type for all nodes"
  type        = string
  default     = "t3.small"
}

variable "clients_per_region" {
  description = "Number of client nodes per region"
  type        = number
  default     = 3
}

variable "client_cpu" {
  description = "CPU MHz advertised by each client"
  type        = number
  default     = 1800
}

variable "client_memory" {
  description = "Memory MB advertised by each client"
  type        = number
  default     = 1800
}

variable "us_region" {
  type    = string
  default = "us-east-1"
}

variable "au_region" {
  type    = string
  default = "ap-southeast-2"
}
