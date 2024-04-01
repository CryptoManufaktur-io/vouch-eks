#!/usr/bin/env bash
set -ex

# Destroy deployments, services and related pods.
terraform destroy -target=kubernetes_cluster_role.traefik_role \
    -target=kubernetes_cluster_role_binding.traefik_role_binding \
    -target=kubernetes_config_map.prometheus-config \
    -target=kubernetes_config_map.promtail-config \
    -target=kubernetes_config_map.vouch1-config \
    -target=kubernetes_deployment.prometheus \
    -target=kubernetes_deployment.traefik \
    -target=kubernetes_deployment.vouch1 \
    -target=kubernetes_ingress_v1.vouch_ingress \
    -target=kubernetes_persistent_volume_claim_v1.traefik_pvc \
    -target=kubernetes_persistent_volume_v1.traefik_pv \
    -target=kubernetes_secret.vouch1-secret \
    -target=kubernetes_service.traefik_metrics \
    -target=kubernetes_service.traefik_service \
    -target=kubernetes_service.vouch1-mev \
    -target=kubernetes_service.vouch_metrics \
    -target=kubernetes_service_account.traefik_account

cluster_region=$(echo $(terraform output -raw kubernetes_cluster_arn) | cut -d':' -f4)
cluster_name=$(terraform output -raw kubernetes_cluster_name)

# Delete load balancer controler iam service account
HTTPS_PROXY=http://localhost:8888 eksctl delete iamserviceaccount \
  --cluster=$cluster_name \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --region $cluster_region

# Destroy EKS cluster
terraform destroy -target=module.eks

# Everything else.
terraform destroy
