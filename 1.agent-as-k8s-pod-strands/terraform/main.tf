# ─── VPC ──────────────────────────────────────────────────────────────────
# EKS needs its own VPC. Using a /16 gives us 65K IPs.
# We tag it with "kubernetes.io/cluster/${name}" so EKS can find it.

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true   # Required for EKS node → control plane DNS
  enable_dns_hostnames = true   # Required for EKS nodes to register

  tags = {
    Name = "${var.cluster_name}-vpc"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ─── INTERNET GATEWAY ────────────────────────────────────────────────────
# Needed so public subnets can reach the internet (ECR image pulls, etc.)

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.cluster_name}-igw" }
}

# ─── PUBLIC SUBNETS (one per AZ) ─────────────────────────────────────────
# EKS requires subnets in at least 2 AZs for control plane HA.
# We use public subnets to avoid NAT Gateway costs ($0.045/hr!).
# Tag: kubernetes.io/role/elb = "1" → lets EKS create Load Balancers here

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet("10.0.0.0/16", 8, count.index)
  availability_zone = element(var.availability_zones, count.index)

  map_public_ip_on_launch = true   # Nodes get public IPs for internet access

  tags = {
    Name = "${var.cluster_name}-public-${count.index}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.cluster_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ─── SECURITY GROUPS ──────────────────────────────────────────────────────
# Node security group: nodes need to talk to each other + EKS control plane

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  vpc_id      = aws_vpc.main.id
  description = "EKS node security group"

  ingress {
    description = "Allow all inter-node traffic"
    from_port   = 0; to_port = 0; protocol = "-1"
    self        = true
  }

  ingress {
    description = "EKS control plane → kubelet"
    from_port   = 443; to_port = 443; protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "EKS control plane → kubelet API"
    from_port   = 10250; to_port = 10250; protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-nodes-sg" }
}