#!/usr/bin/env bash
set -ex

# Deploy only the VPC and VMS
terraform apply -target=module.compute -target=aws_security_group.allow_bastion_ssh -target=aws_iam_policy.aws_load_balancer_controller_policy

# Deploy the EKS Cluster.
terraform apply -target=module.eks

# Deploy the AWS load balancer controller
cluster_region=$(echo $(terraform output -raw kubernetes_cluster_arn) | cut -d':' -f4)
cluster_name=$(terraform output -raw kubernetes_cluster_name)
vpc_id=$(terraform output -raw vpc_id)
aws_account_id=$(terraform output -raw aws_account_id)
policy_name=$(terraform output -raw lb_controller_policy_name)

aws eks update-kubeconfig --region $cluster_region --name $cluster_name
# eksctl utils associate-iam-oidc-provider --region $cluster_region --cluster $cluster_name --approve

# echo $cluster_name
# echo $aws_account_id
# echo $policy_name
# echo $cluster_region

# Savior when nothing else works HAHA!!
# HTTPS_PROXY=http://localhost:8888 eksctl delete iamserviceaccount \
#   --cluster=$cluster_name \
#   --namespace=kube-system \
#   --name=aws-load-balancer-controller \
#   --region $cluster_region \

HTTPS_PROXY=http://localhost:8888 eksctl create iamserviceaccount \
  --cluster=$cluster_name \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::$aws_account_id:policy/$policy_name \
  --override-existing-serviceaccounts \
  --approve \
  --region $cluster_region \

# exit

helm repo add eks https://aws.github.io/eks-charts
HTTPS_PROXY=http://localhost:8888 kubectl apply -k "github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

HTTPS_PROXY=http://localhost:8888 helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --set clusterName=$cluster_name \
    --set serviceAccount.create=false \
    --set region=$cluster_region \
    --set vpcId=$vpc_id \
    --set serviceAccount.name=aws-load-balancer-controller \
    -n kube-system

# Kill the existing ssh session to the bastion proxy.
kill $(ps aux | grep '[:]localhost:8888 -N -q -f' | awk '{print $2}')

# Deploy everything else.
terraform apply
