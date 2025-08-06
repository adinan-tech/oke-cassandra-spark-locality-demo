variable "tenancy_ocid" {}
variable "compartment_ocid" {}
variable "vcn_id" {}
variable "subnet_id" {}
variable "lb_subnet_id" {}
variable "cluster_name" {}
variable "kubernetes_version" {

}
variable "node_pool_name" {}
variable "node_pool_shape" {}
variable "node_pool_size" {}
variable "cluster_options_add_ons_is_kubernetes_dashboard_enabled" {}
variable "cluster_options_admission_controller_options_is_pod_security_policy_enabled" {}
variable "nodepool_image_version" {}
variable "ssh_public_key" {}
variable "create_new_oke_cluster" {}
variable "existing_oke_cluster_id" {}
variable "cluster_endpoint_config_is_public_ip_enabled" {}
variable "endpoint_subnet_id" {}
variable "node_pool_node_shape_config_ocpus" {}
variable "node_pool_node_shape_config_memory_in_gbs" {}
variable "is_flex_node_shape" {}
