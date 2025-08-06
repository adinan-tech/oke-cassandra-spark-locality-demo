resource "oci_containerengine_cluster" "oke_dl_cluster" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = var.cluster_name
  vcn_id             = var.vcn_id

  endpoint_config {
    is_public_ip_enabled = var.cluster_endpoint_config_is_public_ip_enabled
    # nsg_ids = var.cluster_endpoint_config_nsg_ids
    subnet_id = var.endpoint_subnet_id
  }

  options {
    add_ons {
      is_kubernetes_dashboard_enabled = var.cluster_options_add_ons_is_kubernetes_dashboard_enabled
      is_tiller_enabled               = false # Default is false, left here for reference
    }
    admission_controller_options {
      is_pod_security_policy_enabled = var.cluster_options_admission_controller_options_is_pod_security_policy_enabled
    }
    service_lb_subnet_ids = [var.lb_subnet_id]
  }

  count = var.create_new_oke_cluster ? 1 : 0
}

resource "oci_containerengine_node_pool" "dl_node_pool" {
  cluster_id         = var.create_new_oke_cluster ? oci_containerengine_cluster.oke_dl_cluster[0].id : var.existing_oke_cluster_id
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = var.node_pool_name
  node_shape         = var.node_pool_shape
  ssh_public_key     = var.ssh_public_key
  node_metadata = var.nodepool_image_version > 7.9 ? {
    user_data = data.template_cloudinit_config.config_ol8[0].rendered
  } : null
  node_config_details {
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = var.subnet_id
    }
    size = var.node_pool_size
  }


  dynamic "node_shape_config" {
    for_each = var.is_flex_node_shape ? [1] : []
    content {
      ocpus         = var.node_pool_node_shape_config_ocpus
      memory_in_gbs = var.node_pool_node_shape_config_memory_in_gbs
    }
  }

  node_source_details {
    source_type = "IMAGE"
    image_id = element([
      for source in data.oci_containerengine_node_pool_option.np_option.sources : source.image_id
      if(
        length(regexall("GPU", var.node_pool_shape)) > 0 ? length(regexall("Oracle-Linux-${var.nodepool_image_version}-Gen2-GPU-20[0-9]*.*-OKE-${substr(var.kubernetes_version, 1, -1)}", source.source_name)) > 0 :
    length(regexall("Oracle-Linux-${var.nodepool_image_version}-20[0-9]*.*-OKE-${substr(var.kubernetes_version, 1, -1)}", source.source_name)) > 0)], 0)
  }

  initial_node_labels {
    key   = "name"
    value = var.node_pool_name
  }
  
}

