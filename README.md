# vouch-eks

This terraform project creates all the infrastructure necessary for [vouchdirk-docker vouch](https://github.com/CryptoManufaktur-io/vouchdirk-docker/) in AWS EKS.

The infrastructure includes:

- 1 EKS Private Cluster running on Fargate, with:
    - Vouch
    - Prometheus
    - ExternalDNS
    - Traefik
- Security Group to allow ssh traffic from the defined addresses
- 1 EC2 instance to use as bastion host and proxy for kubectl, helm and eksctl
- 1 NAT gateway for the Pods to connect to the internet
- 2 Private subnets
- 2 Public subnets

The EKS cluster uses Authorized Networks and only traffic from the bastion host has access to the Control Plane. 

In order for terraform to create the multiple Kubernetes resources, an SSH tunnel is created which then proxies the traffic to the Kubernetes Control Plane.

The tunnel is achieved by an External Data Source which runs the necessary shell commands.

Vouch's MEV-boost service is exposed via Traefik on a Service behind a Network Load Balancer.

## Traefik as Ingress in EKS

When the Traefik `LoadBalancer` Service is created in Kubernetes, the [AWS Load Balancer Controller](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html) add-on creates a Network Load Balancer and Target Group using the Fargate nodes IP addresses. Traefik then becomes the Ingress Controller and handles all the traffic routing into the pods.

Configuration of the NLB is done via annotations and spec on the Traefik Service. NLBs don't have firewalls so we use `loadBalancerSourceRanges` to limit the traffic.

## Requirements

- Cloudflare Global API keys.
- [aws cli](https://aws.amazon.com/cli/) with a profile already configured
- [kubectl cli](https://kubernetes.io/docs/tasks/tools/#kubectl)
- [eksctl cli](https://eksctl.io/)
- [helm cli](https://helm.sh/docs/intro/install/)

## Setup

- Create an S3 bucket for the Terraform state data.
- Generate the [vouchdirk-docker](https://github.com/CryptoManufaktur-io/vouchdirk-docker/#initial-setup) `config/` folder and copy it to the root of project folder.
- Copy `backend.conf.sample` to `backend.conf` and set the Bucket name and Prefix for Terraform state data.
- Copy `terraform.tfvars.sample` to `terraform.tfvars` and modify as needed.
- Copy `prometheus-custom.yml.sample` to `prometheus-custom.yml` and modify as needed. Prometheus is not exposed in this use case and remote write is expected.
- Initialize terraform:
```shell
terraform init -backend-config=backend.conf
```
- Set AWS environment variables:
```shell
export AWS_PROFILE=your-profile-name
export AWS_DEFAULT_REGION=us-east-2
```
- Deploy
```shell
./deploy.sh
```

## Using kubectl

In order to create the ssh tunnel when needed, you can execute `terraform plan`.

You can then use the environment variable `HTTPS_PROXY` with the kubectl command for the requests to be tunneled and proxied.

E.g:

```shell
HTTPS_PROXY=localhost:8888 kubectl get pods
```

Once finished, you can run `killall ssh` to kill the ssh tunnel or you can find the specific process ID and kill it if you need to keep other ssh processes running.
