# ArgoCD Management Cluster Configuration
# This creates a dedicated cluster for managing multiple workload clusters

# Use the same VPC as the existing cluster
data "aws_vpc" "default" {
  default = true
}

# Get subnets only in EKS-supported AZs
data "aws_subnets" "eks_subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  
  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c"]
  }
}

# IAM Role for ArgoCD EKS Cluster
resource "aws_iam_role" "argocd_cluster" {
  name = "argocd-mgmt-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "argocd_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.argocd_cluster.name
}

# IAM Role for ArgoCD Node Group
resource "aws_iam_role" "argocd_nodes" {
  name = "argocd-mgmt-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "argocd_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.argocd_nodes.name
}

resource "aws_iam_role_policy_attachment" "argocd_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.argocd_nodes.name
}

resource "aws_iam_role_policy_attachment" "argocd_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.argocd_nodes.name
}

# ArgoCD Management EKS Cluster
resource "aws_eks_cluster" "argocd" {
  name     = "argocd-mgmt-cluster"
  role_arn = aws_iam_role.argocd_cluster.arn
  version  = "1.31"

  vpc_config {
    subnet_ids              = data.aws_subnets.eks_subnets.ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.argocd_cluster_policy
  ]
}

# ArgoCD Node Group (smaller since it's just for management)
resource "aws_eks_node_group" "argocd" {
  cluster_name    = aws_eks_cluster.argocd.name
  node_group_name = "argocd-mgmt-node-group"
  node_role_arn   = aws_iam_role.argocd_nodes.arn
  subnet_ids      = data.aws_subnets.eks_subnets.ids

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  depends_on = [
    aws_iam_role_policy_attachment.argocd_worker_node_policy,
    aws_iam_role_policy_attachment.argocd_cni_policy,
    aws_iam_role_policy_attachment.argocd_container_registry_policy,
  ]
}

# Data source to get OIDC provider for IRSA (needed for AWS Load Balancer Controller)
data "tls_certificate" "argocd_cluster" {
  url = aws_eks_cluster.argocd.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "argocd_cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.argocd_cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.argocd.identity[0].oidc[0].issuer
}

# Outputs
output "argocd_cluster_endpoint" {
  description = "ArgoCD management cluster endpoint"
  value       = aws_eks_cluster.argocd.endpoint
}

output "argocd_cluster_name" {
  description = "ArgoCD management cluster name"
  value       = aws_eks_cluster.argocd.name
}

output "argocd_configure_kubectl" {
  description = "Configure kubectl for ArgoCD cluster"
  value       = "aws eks update-kubeconfig --region us-east-1 --name ${aws_eks_cluster.argocd.name}"
}

output "argocd_install_commands" {
  description = "Commands to install ArgoCD"
  value = <<-EOT
    # 1. Configure kubectl
    aws eks update-kubeconfig --region us-east-1 --name ${aws_eks_cluster.argocd.name}
    
    # 2. Install ArgoCD
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    # 3. Patch ArgoCD server to use LoadBalancer
    kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
    
    # 4. Wait for LoadBalancer (takes 2-3 minutes)
    kubectl get svc argocd-server -n argocd -w
    
    # 5. Get initial admin password
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    
    # 6. Get ArgoCD URL
    kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  EOT
}

output "next_steps" {
  description = "What to do after cluster creation"
  value = <<-EOT
    After 'terraform apply' completes:
    
    1. Run the commands from 'argocd_install_commands' output
    2. Access ArgoCD UI at the LoadBalancer URL (https://<LB-URL>)
    3. Login with username 'admin' and the password from step 5
    4. Add your workload clusters to ArgoCD for management
    
    Note: The LoadBalancer will add ~$18/month (~$0.60/day) to your costs
  EOT
}