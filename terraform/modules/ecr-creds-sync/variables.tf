variable "management_id" {
  description = "Management cluster identifier, used to namespace IAM resource names."
  type        = string
}

variable "eks_cluster_name" {
  description = "Name of the EKS management cluster for the Pod Identity association."
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources."
  type        = map(string)
  default     = {}
}

