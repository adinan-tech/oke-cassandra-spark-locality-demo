variable "availability_domain" {
  default = "0"
}
variable "compartment_ocid" {}
variable "subnet_id" {}
variable "instance_name" {}
variable "instance_shape" {}
variable "image_id" {}
variable "public_edge_node" {}
variable "ssh_public_key" {}
variable "oke_cluster_id" {}
variable "nodepool_id" {}
variable "user_data" {}
variable "bastion_shape_config_ocpus" {}
variable "bastion_shape_config_memory_in_gbs" {}
variable "is_flex_bastion_shape" {}

