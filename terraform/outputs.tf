output "kubernetes_cluster_name" {
  value       = module.gke.name
  description = "GKE Cluster Name"
}

output "kubernetes_cluster_host" {
  value       = module.gke.endpoint
  description = "GKE Cluster Host"
}

output "ingress_ip_address" {
  value       = google_compute_global_address.ingress_ip.address
  description = "External IP address for application ingress"
}

output "iot_application_url" {
  value       = "http://iot.${google_compute_global_address.ingress_ip.address}.nip.io"
  description = "URL to access the IoT application frontend"
}

output "iot_api_url" {
  value       = "http://iot.${google_compute_global_address.ingress_ip.address}.nip.io/api"
  description = "URL to access the IoT application API"
}