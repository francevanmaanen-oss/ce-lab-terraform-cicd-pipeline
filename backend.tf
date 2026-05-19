terraform {
  backend "s3" {
    bucket         = "ce-bootcamp-tfstate-francevanmaanen-oss"
    key            = "m5-02-cicd/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}