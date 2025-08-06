resource "oci_core_vcn" "dl_vcn" {
  count          = var.useExistingVcn ? 0 : 1
  cidr_block     = var.VCN_CIDR
  compartment_id = var.compartment_ocid
  display_name   = "Data locality - ${random_string.deploy_id.result}"
  dns_label      = var.vcn_dns_label
}

resource "oci_core_internet_gateway" "dl_internet_gateway" {
  count          = var.useExistingVcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "dl_internet_gateway"
  vcn_id         = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id
}

resource "oci_core_nat_gateway" "nat_gateway" {
  count          = var.useExistingVcn ? 0 : 1
  compartment_id = var.compartment_ocid
  vcn_id         = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id
  display_name   = "nat_gateway"
}

resource "oci_core_service_gateway" "dl_service_gateway" {
  count          = var.useExistingVcn ? 0 : 1
  compartment_id = var.compartment_ocid
  services {
    service_id = data.oci_core_services.net_services.services[0]["id"]
  }
  vcn_id       = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id
  display_name = "dl Service Gateway"
}

resource "oci_core_route_table" "RouteForComplete" {
  count          = var.useExistingVcn ? 0 : 1
  compartment_id = var.compartment_ocid
  vcn_id         = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id
  display_name   = "RouteTableForComplete"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.dl_internet_gateway.*.id[count.index]
  }
}

resource "oci_core_route_table" "private" {
  count          = var.useExistingVcn ? 0 : 1
  compartment_id = var.compartment_ocid
  vcn_id         = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id
  display_name   = "private"

  route_rules {
    #      destination       = var.oci_service_gateway
    destination       = data.oci_core_services.net_services.services[0]["cidr_block"]
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.dl_service_gateway.*.id[count.index]
  }

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gateway.*.id[count.index]
  }
}

# Best practice calls for using Network Security Group as opposed to Security Lists
# next enhancement will be to eliminate security lists completely

resource "oci_core_security_list" "EdgeSubnet" {
  count          = var.useExistingVcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "Edge Subnet"
  vcn_id         = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    tcp_options {
      max = 22
      min = 22
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = 80
      min = 80
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = 443
      min = 443
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = 22
      min = 22
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = var.service_port
      min = var.service_port
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = 6443
      min = 6443
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = var.VCN_CIDR
  }
}

resource "oci_core_security_list" "PrivateSubnet" {
  count          = var.useExistingVcn ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "Private"
  vcn_id         = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  #  egress_security_rules {
  #    protocol    = "6"
  #    destination = var.VCN_CIDR
  #  }

  ingress_security_rules {
    protocol = "all"
    source   = var.VCN_CIDR
  }
  ingress_security_rules {
    description = "Allow  traffic  from load balancers (public subnet) to worker nodes"
    protocol    = "6"
    source      = "0.0.0.0/0"
    tcp_options {
      min = 30000
      max = 32767
    }
  }
}




resource "oci_core_subnet" "edge" {
  count             = var.useExistingVcn ? 0 : 1
  cidr_block        = var.edge_cidr
  display_name      = "edge"
  compartment_id    = var.compartment_ocid
  vcn_id            = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id
  route_table_id    = oci_core_route_table.RouteForComplete[count.index].id
  security_list_ids = [oci_core_security_list.EdgeSubnet.*.id[count.index]]
  dhcp_options_id   = oci_core_vcn.dl_vcn[count.index].default_dhcp_options_id
  dns_label         = "edge"
}

resource "oci_core_subnet" "private" {
  count                      = var.useExistingVcn ? 0 : 1
  cidr_block                 = var.private_cidr
  display_name               = "private"
  compartment_id             = var.compartment_ocid
  vcn_id                     = var.useExistingVcn ? var.custom_vcn[0] : oci_core_vcn.dl_vcn.0.id
  route_table_id             = oci_core_route_table.private[count.index].id
  security_list_ids          = [oci_core_security_list.PrivateSubnet.*.id[count.index]]
  dhcp_options_id            = oci_core_vcn.dl_vcn[count.index].default_dhcp_options_id
  prohibit_public_ip_on_vnic = "true"
  dns_label                  = "private"
}


