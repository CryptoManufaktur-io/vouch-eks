# Get cluster region and name to update kubeconfig.
cluster_region=$(echo $(terraform output -raw kubernetes_cluster_arn) | cut -d':' -f4)
cluster_name=$(terraform output -raw kubernetes_cluster_name)

aws eks update-kubeconfig --region $cluster_region --name $cluster_name
