terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  
  backend "gcs" {
    bucket = "doris-terraform-state"
    prefix = "doris-disaggregated"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE Cluster Name"
  type        = string
  default     = "doris-cluster"
}

variable "network_name" {
  description = "VPC Network Name"
  type        = string
  default     = "doris-network"
}

variable "subnet_name" {
  description = "Subnet Name"
  type        = string
  default     = "doris-subnet"
}

variable "gcs_bucket_name" {
  description = "GCS Bucket for Doris Data"
  type        = string
  default     = "doris-data-bucket"
}

locals {
  zones = ["${var.region}-a", "${var.region}-b", "${var.region}-c"]
}

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 9.0"

  project_id   = var.project_id
  network_name = var.network_name

  subnets = [
    {
      subnet_name           = var.subnet_name
      subnet_ip             = "10.0.0.0/16"
      subnet_region         = var.region
      subnet_private_access = true
    }
  ]

  secondary_ranges = {
    "${var.subnet_name}" = [
      {
        range_name    = "pods"
        ip_cidr_range = "10.4.0.0/14"
      },
      {
        range_name    = "services"
        ip_cidr_range = "10.0.32.0/20"
      }
    ]
  }
}

resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = module.vpc.network_name

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_container_cluster" "doris_cluster" {
  name     = var.cluster_name
  location = var.region

  network    = module.vpc.network_name
  subnetwork = var.subnet_name

  initial_node_count = 1

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
    managed_prometheus {
      enabled = true
    }
  }

  addons_config {
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
  }

  timeouts {
    create = "30m"
    update = "40m"
  }
}

resource "google_container_node_pool" "fe_pool" {
  name       = "fe-pool"
  location   = var.region
  cluster    = google_container_cluster.doris_cluster.name
  node_count = 3

  node_config {
    machine_type    = "n2-standard-8"
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.doris_sa.email
    
    labels = {
      component = "fe"
    }
    
    taint = []
    
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_container_node_pool" "ms_pool" {
  name       = "ms-pool"
  location   = var.region
  cluster    = google_container_cluster.doris_cluster.name
  node_count = 3

  node_config {
    machine_type    = "n2-standard-4"
    disk_size_gb    = 50
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.doris_sa.email
    
    labels = {
      component = "ms"
    }
    
    taint = []
    
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_container_node_pool" "be_pool" {
  name    = "be-pool"
  location = var.region
  cluster  = google_container_cluster.doris_cluster.name
  
  autoscaling {
    min_node_count = 3
    max_node_count = 20
  }

  node_config {
    machine_type    = "n2-highmem-16"
    disk_size_gb    = 100
    disk_type       = "pd-ssd"
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.doris_sa.email
    
    labels = {
      component = "be"
    }
    
    taint = []
    
    local_ssd_count = 1
    
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_container_node_pool" "cn_spot_pool" {
  name     = "cn-spot-pool"
  location = var.region
  cluster  = google_container_cluster.doris_cluster.name
  
  autoscaling {
    min_node_count = 3
    max_node_count = 50
  }

  node_config {
    machine_type    = "n2-highmem-16"
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.doris_sa.email
    
    labels = {
      component = "cn-spot"
    }
    
    taint {
      key    = "cloud.google.com/gke-preemptible"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
    
    preemptible  = true
    spot         = true
    
    local_ssd_count = 1
    
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_container_node_pool" "cn_ondemand_pool" {
  name     = "cn-ondemand-pool"
  location = var.region
  cluster  = google_container_cluster.doris_cluster.name
  
  autoscaling {
    min_node_count = 0
    max_node_count = 10
  }

  node_config {
    machine_type    = "n2-highmem-16"
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.doris_sa.email
    
    labels = {
      component = "cn-ondemand"
    }
    
    taint = []
    
    local_ssd_count = 1
    
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_service_account" "doris_sa" {
  account_id   = "doris-sa"
  display_name = "Doris Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "doris_sa_gcs" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.doris_sa.email}"
}

resource "google_project_iam_member" "doris_sa_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.doris_sa.email}"
}

resource "google_project_iam_member" "doris_sa_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.doris_sa.email}"
}

resource "google_storage_bucket" "doris_data" {
  name          = var.gcs_bucket_name
  location      = var.region
  force_destroy = false
  
  storage_class = "STANDARD"
  
  uniform_bucket_level_access {
    enabled = true
  }
  
  versioning {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type = "Delete"
    }
  }
  
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  
  logging {
    log_bucket = "${var.gcs_bucket_name}-logs"
  }
  
  retention_policy {
    retention_period = 2592000
  }
  
  encryption {
    default_kms_key_name = google_kms_crypto_key.doris_key.id
  }
}

resource "google_storage_bucket" "doris_logs" {
  name          = "${var.gcs_bucket_name}-logs"
  location      = var.region
  force_destroy = false
  
  storage_class = "NEARLINE"
  
  uniform_bucket_level_access {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_kms_key_ring" "doris_keyring" {
  name     = "doris-keyring"
  location = var.region
}

resource "google_kms_crypto_key" "doris_key" {
  name            = "doris-key"
  key_ring        = google_kms_key_ring.doris_keyring.id
  rotation_period = "7776000s"
  
  destroy_scheduled_duration = "86400s"
}

resource "google_kms_crypto_key_iam_member" "doris_key_iam" {
  crypto_key_id = google_kms_crypto_key.doris_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.doris_sa.email}"
}

resource "google_compute_global_address" "doris_ingress_ip" {
  name = "doris-ingress-ip"
}

output "cluster_endpoint" {
  value = google_container_cluster.doris_cluster.endpoint
}

output "cluster_name" {
  value = google_container_cluster.doris_cluster.name
}

output "gcs_bucket" {
  value = google_storage_bucket.doris_data.url
}

output "doris_sa_email" {
  value = google_service_account.doris_sa.email
}

output "ingress_ip" {
  value = google_compute_global_address.doris_ingress_ip.address
}
