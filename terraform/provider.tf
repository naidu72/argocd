provider "kubernetes" {
  config_path = "/home/naidu/.kube/config"
}

# provider "helm" {
#   kubernetes {
#     config_path = "/home/frontier/.kube/local"
#   }
# }

# provider "helm" {
#   # no nested kubernetes block
# }

# provider "helm" {
#   kubernetes {
#     host                   = aws_eks_cluster.demo.endpoint
#     cluster_ca_certificate = base64decode(aws_eks_cluster.demo.certificate_authority[0].data)
#     exec {
#       api_version = "client.authentication.k8s.io/v1beta1"
#       args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.demo.id]
#       command     = "aws"
#     }
#   }
# }