variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "notify_email" {
  description = "Where processing summaries and alarms are sent. You must confirm the subscription email from AWS."
  type        = string
  sensitive   = true # keeps your email out of plan output, which is posted on public pull requests

  # A missing GitHub secret arrives as an empty string. Fail clearly instead.
  validation {
    condition     = can(regex("^\\S+@\\S+\\.\\S+$", var.notify_email))
    error_message = "notify_email must be an email address. In GitHub, check the NOTIFY_EMAIL secret."
  }
}

variable "lambda_timeout_seconds" {
  type    = number
  default = 60
}
