output "BASTION_PUBLIC_IP" { value = var.public_edge_node ? module.bastion.public_ip : "No public IP assigned" }

output "INFO" { value = "Data Locality with Cassandra and Spark" }
