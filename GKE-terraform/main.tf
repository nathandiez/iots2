# main.tf

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.14.0, < 7.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0.0"
}

# Set the GCP project, region, and zone
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

data "google_client_config" "default" {}

resource "google_compute_network" "vpc" {
  name                    = "${var.project_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.project_name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.0.0.0/16"
  
  secondary_ip_range {
    range_name    = "pod-range"
    ip_cidr_range = "10.1.0.0/16"
  }
  
  secondary_ip_range {
    range_name    = "service-range"
    ip_cidr_range = "10.2.0.0/16"
  }
}
# Create Cloud Router for NAT
resource "google_compute_router" "router" {
  name    = "${var.project_name}-nat-router"
  region  = var.region
  network = google_compute_network.vpc.name
}

# Configure Cloud NAT
resource "google_compute_router_nat" "nat" {
  name                               = "${var.project_name}-nat-config"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Reserve a static external IP for ingress
resource "google_compute_global_address" "ingress_ip" {
  name = "${var.project_name}-ingress-ip"
}

module "gke" {
  source                     = "terraform-google-modules/kubernetes-engine/google"
  project_id                 = var.project_id
  name                       = "${var.project_name}-cluster"
  regional                   = false
  region                     = var.region
  zones                      = [var.zone]
  network                    = google_compute_network.vpc.name
  subnetwork                 = google_compute_subnetwork.subnet.name
  ip_range_pods              = "pod-range"
  ip_range_services          = "service-range"
  http_load_balancing        = true
  network_policy             = true
  remove_default_node_pool   = true
  deletion_protection        = false
  
  node_pools = [
    {
      name               = "default-node-pool"
      machine_type       = "e2-medium"
      node_locations     = var.zone
      min_count          = 3
      max_count          = 3
      disk_size_gb       = 30
      disk_type          = "pd-standard"
      image_type         = "COS_CONTAINERD"
      auto_repair        = true
      auto_upgrade       = true
      initial_node_count = 3
    }
  ]
}

# Configure kubectl to connect to the new cluster
resource "null_resource" "configure_kubectl" {
  depends_on = [module.gke]

  provisioner "local-exec" {
    command = "gcloud container clusters get-credentials ${var.project_name}-cluster --zone ${var.zone} --project ${var.project_id}"
  }
}

# Deploy cert-manager and other resources using init.sh script
resource "null_resource" "deploy_iot_resources" {
  depends_on = [null_resource.configure_kubectl]

  provisioner "local-exec" {
    command = "cd .. && ./init.sh"
  }
}

# Deploy the IoT application using deploy.sh script
resource "null_resource" "deploy_iot_app" {
  depends_on = [null_resource.deploy_iot_resources, google_compute_global_address.ingress_ip]

  provisioner "local-exec" {
    command = "cd .. && INGRESS_IP=${google_compute_global_address.ingress_ip.address} ./deploy.sh"
  }
}