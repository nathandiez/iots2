variable "project_id" {
  description = "GCP project ID"
  type        = string
  default     = "gkeiots2"
}

variable "project_name" {
  description = "Project name to use for resource naming"
  type        = string
  default     = "iot-system"
}

variable "region" {
  description = "GCP region to deploy resources"
  type        = string
  default     = "us-east1"
}

variable "zone" {
  description = "GCP zone for zonal resources"
  type        = string
  default     = "us-east1-b"
}