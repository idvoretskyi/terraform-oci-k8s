/**
 * Network Module for OCI Kubernetes
 * 
 * This module creates the network infrastructure for an OKE cluster including:
 * - Virtual Cloud Network (VCN)
 * - Internet Gateway
 * - NAT Gateway (optional)
 * - Route Tables (public and private)
 * - Security Lists with enhanced rules
 * - Service Subnet for K8s API
 * - Worker Subnet for K8s Nodes
 * - DHCP Options
 */

locals {
  # Resource naming with consistent pattern
  resource_name_prefix = "${var.prefix}-network"

  # Default security tags
  security_tags = {
    "ResourceType"       = "Network"
    "SecurityCompliance" = "CIS-OCI-1.2"
    "NetworkType"        = "Kubernetes"
    "AutomatedBy"        = "OpenTofu"
  }

  # Combined tags for all resources
  all_tags = merge(var.tags, local.security_tags)

  # CIDR blocks used for security rules
  all_icmp_type = 254  # Updated from 255 to comply with OCI limit of 254
  all_icmp_code = 16   # Updated from 255 to comply with OCI limit of 16

  # Calculate if we need private networking
  create_private_resources = !var.enable_public_ips
}

#######################
# Core VCN Resources  #
#######################

# Virtual Cloud Network (VCN)
resource "oci_core_virtual_network" "vcn" {
  compartment_id = var.compartment_id
  cidr_block     = var.vcn_cidr
  display_name   = "${local.resource_name_prefix}-vcn"
  dns_label      = "${var.prefix}vcn"

  freeform_tags = merge(
    local.all_tags,
    { "Component" = "VCN" }
  )
}

# Internet Gateway for public internet access
resource "oci_core_internet_gateway" "internet_gateway" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "${local.resource_name_prefix}-igw"
  enabled        = true

  freeform_tags = merge(
    local.all_tags,
    { "Component" = "InternetGateway" }
  )
}

# NAT Gateway for private worker nodes (only created if public IPs are disabled)
resource "oci_core_nat_gateway" "nat_gateway" {
  count          = local.create_private_resources ? 1 : 0
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "${local.resource_name_prefix}-natgw"

  freeform_tags = merge(
    local.all_tags,
    { "Component" = "NatGateway" }
  )
}

# Service Gateway for accessing OCI services without internet
resource "oci_core_service_gateway" "service_gateway" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "${local.resource_name_prefix}-svcgw"

  services {
    service_id = data.oci_core_services.all_oci_services.services[0].id
  }

  freeform_tags = merge(
    local.all_tags,
    { "Component" = "ServiceGateway" }
  )
}

# Get list of available OCI Services
data "oci_core_services" "all_oci_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

#######################
# Routing Resources   #
#######################

# Public route table (for internet-facing resources)
resource "oci_core_route_table" "public_route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "${local.resource_name_prefix}-public-rt"

  # Route internet-bound traffic through IGW
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.internet_gateway.id
    description       = "Default route through Internet Gateway"
  }

  freeform_tags = merge(
    local.all_tags,
    { "Component" = "PublicRouteTable" }
  )
}

# Private route table (for internal resources)
resource "oci_core_route_table" "private_route_table" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "${local.resource_name_prefix}-private-rt"

  # Route internet-bound traffic through NAT Gateway if enabled
  dynamic "route_rules" {
    for_each = local.create_private_resources ? [1] : []
    content {
      destination       = "0.0.0.0/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = oci_core_nat_gateway.nat_gateway[0].id
      description       = "Default route through NAT Gateway"
    }
  }

  # Route to OCI services through Service Gateway
  route_rules {
    destination_type  = "SERVICE_CIDR_BLOCK"
    destination       = data.oci_core_services.all_oci_services.services[0].cidr_block
    network_entity_id = oci_core_service_gateway.service_gateway.id
    description       = "Route to all OCI services"
  }

  freeform_tags = merge(
    local.all_tags,
    { "Component" = "PrivateRouteTable" }
  )
}

#######################
# Security Lists      #
#######################

# API Endpoint Security List
resource "oci_core_security_list" "api_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "${local.resource_name_prefix}-api-sl"

  # Allow all outbound traffic
  egress_security_rules {
    description = "Allow all outbound traffic"
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # Allow incoming SSH traffic from each authorized CIDR
  dynamic "ingress_security_rules" {
    for_each = var.authorized_ip_ranges
    content {
      description = "Allow SSH from ${ingress_security_rules.value}"
      source      = ingress_security_rules.value
      protocol    = "6" # TCP
      stateless   = true

      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  # Allow incoming Kubernetes API traffic from each authorized CIDR
  dynamic "ingress_security_rules" {
    for_each = var.authorized_ip_ranges
    content {
      description = "Allow Kubernetes API from ${ingress_security_rules.value}"
      source      = ingress_security_rules.value
      protocol    = "6" # TCP
      stateless   = true

      tcp_options {
        min = 6443
        max = 6443
      }
    }
  }

  # Allow incoming traffic to NodePorts from each authorized CIDR
  dynamic "ingress_security_rules" {
    for_each = var.authorized_ip_ranges
    content {
      description = "Allow NodePorts from ${ingress_security_rules.value}"
      source      = ingress_security_rules.value
      protocol    = "6" # TCP
      stateless   = true

      tcp_options {
        min = 30000
        max = 32767
      }
    }
  }

  # Allow ICMP traffic for network diagnostics from each authorized CIDR
  dynamic "ingress_security_rules" {
    for_each = var.authorized_ip_ranges
    content {
      description = "Allow ICMP from ${ingress_security_rules.value}"
      source      = ingress_security_rules.value
      protocol    = "1" # ICMP
      stateless   = true

      icmp_options {
        type = local.all_icmp_type
        code = local.all_icmp_code
      }
    }
  }

  freeform_tags = merge(
    local.all_tags,
    { "Component" = "APISecurityList" }
  )
}

# Worker Nodes Security List
resource "oci_core_security_list" "worker_security_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "${local.resource_name_prefix}-worker-sl"

  # Allow all outbound traffic
  egress_security_rules {
    description = "Allow all outbound traffic"
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  # Allow all traffic between worker nodes
  ingress_security_rules {
    description = "Allow all traffic between worker nodes"
    source      = var.worker_subnet_cidr
    protocol    = "all"
    stateless   = true
  }

  # Allow incoming SSH from each authorized CIDR
  dynamic "ingress_security_rules" {
    for_each = var.authorized_ip_ranges
    content {
      description = "Allow SSH from ${ingress_security_rules.value}"
      source      = ingress_security_rules.value
      protocol    = "6" # TCP
      stateless   = true

      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  # Allow incoming ICMP traffic for network diagnostics from each authorized CIDR
  dynamic "ingress_security_rules" {
    for_each = var.authorized_ip_ranges
    content {
      description = "Allow ICMP from ${ingress_security_rules.value}"
      source      = ingress_security_rules.value
      protocol    = "1" # ICMP
      stateless   = true

      icmp_options {
        type = local.all_icmp_type
        code = local.all_icmp_code
      }
    }
  }

  freeform_tags = {
    "Component"          = "SecurityList"
    "Purpose"            = "WorkerNodes"
    "ResourceType"       = "Network"
    "SecurityCompliance" = "CIS-OCI-1.2"
    "NetworkType"        = "Kubernetes"
    "AutomatedBy"        = "OpenTofu"
    "Project"            = try(var.tags["Project"], "OCI-Kubernetes")
    "Environment"        = try(var.tags["Environment"], "Dev")
  }

  lifecycle {
    create_before_destroy = true
  }
}

#######################
# DHCP Options        #
#######################

resource "oci_core_dhcp_options" "dhcp_options" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_virtual_network.vcn.id
  display_name   = "${local.resource_name_prefix}-dhcp"

  # Use VCN DNS and Custom nameservers
  options {
    type        = "DomainNameServer"
    server_type = "VcnLocalPlusInternet"
  }

  options {
    type                = "SearchDomain"
    search_domain_names = ["${oci_core_virtual_network.vcn.dns_label}.oraclevcn.com"]
  }

  freeform_tags = merge(
    local.all_tags,
    { "Component" = "DHCPOptions" }
  )
}

#######################
# Subnet Resources    #
#######################

# Service Subnet for Kubernetes API
resource "oci_core_subnet" "service_subnet" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_virtual_network.vcn.id
  cidr_block                 = var.service_subnet_cidr
  display_name               = "${local.resource_name_prefix}-service-subnet"
  security_list_ids          = [oci_core_security_list.api_security_list.id]
  route_table_id             = oci_core_route_table.public_route_table.id
  dns_label                  = "${var.prefix}service"
  dhcp_options_id            = oci_core_dhcp_options.dhcp_options.id
  prohibit_public_ip_on_vnic = false

  freeform_tags = {
    "Component" = "Subnet"
    "Purpose"   = "KubernetesAPI"
    "Project"   = try(var.tags["Project"], "OCI-Kubernetes")
    "Environment" = try(var.tags["Environment"], "Dev")
    "ManagedBy" = try(var.tags["ManagedBy"], "OpenTofu")
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [defined_tags]
  }
}

# Worker Subnet for Kubernetes nodes
resource "oci_core_subnet" "worker_subnet" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_virtual_network.vcn.id
  cidr_block                 = var.worker_subnet_cidr
  display_name               = "${local.resource_name_prefix}-worker-subnet"
  security_list_ids          = [oci_core_security_list.worker_security_list.id]
  route_table_id             = local.create_private_resources ? oci_core_route_table.private_route_table.id : oci_core_route_table.public_route_table.id
  dns_label                  = "${var.prefix}worker"
  dhcp_options_id            = oci_core_dhcp_options.dhcp_options.id
  prohibit_public_ip_on_vnic = local.create_private_resources

  freeform_tags = {
    "Component" = "Subnet"
    "Purpose"   = "WorkerNodes"
    "Project"   = try(var.tags["Project"], "OCI-Kubernetes")
    "Environment" = try(var.tags["Environment"], "Dev")
    "ManagedBy" = try(var.tags["ManagedBy"], "OpenTofu")
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [defined_tags]
  }
}

#######################
# Dependencies        #
#######################

# Create a null_resource to handle subnet cleanup
resource "null_resource" "subnet_dependency_waiter" {
  triggers = {
    # Include IDs so this updates when the network changes
    service_subnet_id = oci_core_subnet.service_subnet.id
    worker_subnet_id  = oci_core_subnet.worker_subnet.id
  }

  # This will only run during destruction
  provisioner "local-exec" {
    when    = destroy
    command = "echo 'Waiting for resources to be released from subnets...' && sleep 30"
  }
}
