terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    # Cloud Control API: contorna o deny de GetBucketObjectLockConfiguration
    # imposto pelo SCP do Learner Lab. Ver o cabecalho de main.tf.
    awscc = {
      source = "hashicorp/awscc"
    }
    null = {
      source = "hashicorp/null"
    }
  }
}
