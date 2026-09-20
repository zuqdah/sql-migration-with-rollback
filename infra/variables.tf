variable "resource_group_name" {
  description = "Existing resource group the lab deploys into."
  type        = string
}

variable "location" {
  description = "Region override. Defaults to the resource group's region."
  type        = string
  default     = null
}

variable "sql_admin_group_name" {
  description = "Entra group that administers the SQL server. There are no SQL logins."
  type        = string
}

variable "sql_admin_group_object_id" {
  description = "Object ID of the Entra administrator group."
  type        = string
}

variable "database_name" {
  description = "Target database name."
  type        = string
  default     = "AppDb"
}

variable "max_size_gb" {
  description = "Cap on database size. Serverless bills storage per GB, so this bounds the bill."
  type        = number
  default     = 2
}

variable "auto_pause_minutes" {
  description = "Idle minutes before compute pauses. Paused compute bills nothing."
  type        = number
  default     = 60
}

variable "tags" {
  description = "Tags applied to everything."
  type        = map(string)
  default     = {}
}
