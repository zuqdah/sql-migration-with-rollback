variable "location" {
  description = "Region for the lab."
  type        = string
  default     = "eastus2"
}

variable "github_repository" {
  description = "owner/repo that federates into this subscription."
  type        = string
  default     = "zuqdah/sql-migration-with-rollback"
}

variable "github_repository_owner_id" {
  description = "Numeric owner ID. GitHub's token carries immutable IDs, not names."
  type        = number
}

variable "github_repository_id" {
  description = "Numeric repository ID."
  type        = number
}

variable "github_environment" {
  description = "GitHub environment the deploy job runs in."
  type        = string
  default     = "lab"
}

variable "extra_sql_admins" {
  description = "Object IDs added to the SQL administrator group alongside the deploy identity, so a human can also connect."
  type        = list(string)
  default     = []
}
