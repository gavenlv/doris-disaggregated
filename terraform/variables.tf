variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "cluster_name" {
  type    = string
  default = "doris-cluster"
}

variable "gcs_bucket_name" {
  type    = string
  default = "doris-data-bucket"
}
