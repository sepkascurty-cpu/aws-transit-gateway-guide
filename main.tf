# AWS Transit Gateway hub-and-spoke — main.tf
# Companion to the aws-transit-gateway-guide README.
# Spoke VPCs are assumed to exist (see the aws-vpc-networking-guide repo).
# This file builds: TGW hub (defaults OFF) -> 3 spoke attachments ->
# 2 custom route tables (shared, isolated-prod) with explicit
# association + propagation, a static default route to the inspection
# VPC, and a blackhole route example.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = "ap-southeast-1" # keep hub + spokes in ONE region per TGW
}

variable "spoke_subnets" {
  description = "One subnet per AZ for each spoke attachment (TGW ENIs live here)"
  type = object({
    shared     = list(string)
    prod       = list(string)
    dev        = list(string)
    inspection = list(string)
  })
}

data "aws_vpc" "shared"     { tags = { Name = "vpc-shared-services" } }
data "aws_vpc" "prod"       { tags = { Name = "vpc-prod-app" } }
data "aws_vpc" "dev"        { tags = { Name = "vpc-dev-test" } }
data "aws_vpc" "inspection" { tags = { Name = "vpc-inspection" } }

# ---------------------------------------------------------------- hub ---
resource "aws_ec2_transit_gateway" "hub" {
  description = "central hub router"

  # The two most important lines in this file: never accept the flat
  # default table. Every attachment gets an explicit table below.
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  auto_accept_shared_attachments = "disable" # RAM shares need approval
  dns_support                    = "enable"
  vpn_ecmp_support               = "enable" # ECMP across VPN tunnels

  tags = { Name = "tgw-hub" }
}

# ------------------------------------------------------- attachments ---
resource "aws_ec2_transit_gateway_vpc_attachment" "shared" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = data.aws_vpc.shared.id
  subnet_ids         = var.spoke_subnets.shared
  dns_support        = "enable"
  tags               = { Name = "attach-shared-svc" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "prod" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = data.aws_vpc.prod.id
  subnet_ids         = var.spoke_subnets.prod
  dns_support        = "enable"
  tags               = { Name = "attach-prod" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "dev" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = data.aws_vpc.dev.id
  subnet_ids         = var.spoke_subnets.dev
  tags               = { Name = "attach-dev" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "inspection" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = data.aws_vpc.inspection.id
  subnet_ids         = var.spoke_subnets.inspection

  # REQUIRED for stateful firewalls: keeps return traffic on the same
  # AZ attachment, otherwise asymmetric flows get dropped.
  appliance_mode_support = "enable"
  tags                   = { Name = "attach-inspection" }
}

# ------------------------------------------------------ route tables ---
resource "aws_ec2_transit_gateway_route_table" "shared" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "rt-shared" }
}

resource "aws_ec2_transit_gateway_route_table" "isolated_prod" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  tags               = { Name = "rt-isolated-prod" }
}

# ------------------------------------------------------- association ---
# "Which table do MY packets use?" — one per attachment.
resource "aws_ec2_transit_gateway_route_table_association" "shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.shared.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

resource "aws_ec2_transit_gateway_route_table_association" "prod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_prod.id
}

resource "aws_ec2_transit_gateway_route_table_association" "dev" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.dev.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
  # dev rides the SHARED table: it reaches shared-svc, but the shared
  # table never learns prod's CIDR -> dev cannot reach prod, by design.
}

resource "aws_ec2_transit_gateway_route_table_association" "inspection" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

# ------------------------------------------------------ propagation ---
# "Which tables learn MY routes?" — explicit, per table.
resource "aws_ec2_transit_gateway_route_table_propagation" "shared_into_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.shared.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "inspection_into_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "shared_into_prod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.shared.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_prod.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "prod_into_prod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_prod.id
}

# NOTE: dev's attachment is deliberately NOT propagated anywhere.
# Nobody learns dev's CIDR -> dev is reachable only via its own table.

# ---------------------------------------------------- static routes ---
# Force ALL prod east-west traffic through the inspection VPC.
resource "aws_ec2_transit_gateway_route" "prod_default_to_inspection" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_prod.id
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.inspection.id
}

# Quarantine example: drop a compromised spoke CIDR explicitly without
# touching propagations you will want back later.
resource "aws_ec2_transit_gateway_route" "quarantine_example" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.isolated_prod.id
  destination_cidr_block         = "10.30.99.0/24"
  blackhole                      = true
}

# --------------------------------------------- spoke VPC route tables ---
# Each spoke VPC still needs its own route table pointing inter-VPC
# CIDRs at the TGW attachment. Example for the prod VPC (repeat per
# spoke, per AZ route table):
#
# resource "aws_route" "prod_to_shared" {
#   route_table_id         = aws_route_table.prod_private.id
#   destination_cidr_block = "10.10.0.0/16"          # shared-services
#   transit_gateway_id     = aws_ec2_transit_gateway.hub.id
# }
# resource "aws_route" "prod_to_dev" {
#   route_table_id         = aws_route_table.prod_private.id
#   destination_cidr_block = "10.30.0.0/16"          # dev (will blackhole:
#   transit_gateway_id     = aws_ec2_transit_gateway.hub.id  # no route back)
# }

output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.hub.id
}
