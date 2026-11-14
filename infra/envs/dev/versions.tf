terraform {
  required_version = "= 1.17.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.73.0"
    }
  }
}

terraform {
  backend "s3" {
    key          = "ticketing/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
