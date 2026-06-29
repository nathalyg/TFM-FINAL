aws_region        = "us-east-1"
availability_zone = "us-east-1a"
instance_name     = "tfm"
instance_versions = ["20260627-000000"]
instance_type     = "t3.medium"
root_volume_size  = 20

vpc_cidr    = "10.20.0.0/16"
subnet_cidr = "10.20.1.0/24"

allowed_http_cidr = "0.0.0.0/0"
allowed_ssh_cidr  = "0.0.0.0/0"
ssh_port          = 2222

canonical_owner = "099720109477"

common_tags = {
  Project     = "tfm-terraform"
  Environment = "dev"
  ManagedBy   = "terraform"
}
