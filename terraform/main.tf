terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0" # Using version 3.117.1 based on init output
    }
  }
  required_version = ">= 1.1.0" # Terraform 1.11.3 meets this
}

provider "azurerm" {
  features {}
  # Assumes you are logged in via Azure CLI ('az login')
}

# Define the Azure Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-iotsystem-port"
  location = "eastus" # Ensure this is your desired region
}

# Define the Azure Container Registry (ACR)
resource "azurerm_container_registry" "acr" {
  name                = "ericiots2040525" # Ensure this is your chosen unique name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# Virtual Network (VNet) for AKS
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-iotsystem"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Subnet specifically for AKS Nodes within the VNet
resource "azurerm_subnet" "aks_subnet" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Public IP Address for Kubernetes Ingress
resource "azurerm_public_ip" "ingress_pip" {
  name                = "pip-aks-ingress"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Azure Kubernetes Service (AKS) Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-iotsystem-cluster"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "aks-iotsystem"

  default_node_pool {
    name            = "default"
    node_count      = 3
    vm_size         = "Standard_B2s" # Adjust if desired
    os_disk_size_gb = 30
    vnet_subnet_id  = azurerm_subnet.aks_subnet.id
  }

  identity {
    type = "SystemAssigned"
  }

  # --- CORRECTED SECTION: Added network_profile ---
  network_profile {
    network_plugin     = "kubenet"
    service_cidr       = "10.240.0.0/16"  # Non-overlapping range for K8s services
    dns_service_ip     = "10.240.0.10"   # IP within service_cidr for K8s DNS
    docker_bridge_cidr = "172.17.0.1/16"  # Default bridge CIDR
  }
  # --- END OF CORRECTION ---

  role_based_access_control_enabled = true
}

# --- Outputs ---

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "acr_name" {
   value = azurerm_container_registry.acr.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "aks_cluster_id" {
  value = azurerm_kubernetes_cluster.aks.id
}

output "ingress_public_ip" {
   value = azurerm_public_ip.ingress_pip.ip_address
}

output "aks_node_resource_group" {
  value = azurerm_kubernetes_cluster.aks.node_resource_group
}