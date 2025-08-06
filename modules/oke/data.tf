# Gets a list of Availability Domains
data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}
data "oci_containerengine_node_pool_option" "np_option" {
  node_pool_option_id = var.create_new_oke_cluster ? oci_containerengine_cluster.oke_dl_cluster[0].id : var.existing_oke_cluster_id
}



data "template_file" "ol8" {
  count    = var.nodepool_image_version > 7.9 ? 1 : 0
  template = file("${path.module}/../../userdata/ol8_nodes.sh")
}

data "template_cloudinit_config" "config_ol8" {
  count         = var.nodepool_image_version > 7.9 ? 1 : 0
  gzip          = false
  base64_encode = true

  part {
    filename     = "cloudinit.sh"
    content_type = "text/x-shellscript"
    content      = data.template_file.ol8[0].rendered
  }
}
