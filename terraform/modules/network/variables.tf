variable "project_name" {
  type        = string
  description = "Project name used for resource naming and tagging"
}

variable "environment" {
  type        = string
  description = "Deployment environment (dev, staging, prod)"
}

variable "region" {
  type        = string
  description = "AWS region, used to build VPC endpoint service names"
}

variable "cluster_name" {
  type        = string
  description = "Kubernetes cluster name, applied as kubernetes.io/cluster/<name> subnet tags"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones to spread subnets across"

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least 2 availability zones are required."
  }
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for public subnets (one per AZ)"
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "CIDR blocks for private node subnets (one per AZ)"
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "enable_nat_gateway" {
  type        = bool
  description = "Provision NAT gateways so private subnets reach the internet"
  default     = true
}

variable "single_nat_gateway" {
  type        = bool
  description = "Use one shared NAT gateway instead of one per AZ (cheaper, not HA)"
  default     = true
}

variable "enable_s3_endpoint" {
  type        = bool
  description = "Create the S3 gateway endpoint (keeps ECR layer pulls off NAT)"
  default     = true
}

variable "enable_flow_logs" {
  type        = bool
  description = "Send rejected-traffic VPC flow logs to CloudWatch"
  default     = false
}

variable "flow_logs_retention_days" {
  type        = number
  description = "CloudWatch retention for VPC flow logs"
  default     = 14
}

variable "tags" {
  type        = map(string)
  description = "Additional tags merged into every resource"
  default     = {}
}
