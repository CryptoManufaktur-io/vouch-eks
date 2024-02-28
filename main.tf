resource "aws_security_group" "allow_bastion_ssh" {
  name        = "${var.project_id}-firewall-basion-ssh-only"
  description = "Only allow traffic from Bastion Host"

  depends_on = [
    module.vpc
  ]

  vpc_id = module.vpc.vpc_id

  ingress {
    description      = "SSH from Bastion Host"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = var.ssh_in_addresses
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_id}-firewall-basion-ssh-only"
  }
}

resource "aws_iam_policy" "aws_load_balancer_controller_policy" {
  name        = "${var.project_id}-AWSLoadBalancerControllerIAMPolicy"
  description = "AWS Load Balancer Controller Policy"
  # policy = "${file("${path.module}/AWSLoadBalancerControllerIAMPolicy.json")}"
  policy = "${file("${path.module}/AWSLoadBalancerControllerIAMPolicy.json")}"
}

module "compute" {
  source   = "./modules/compute"
  for_each = var.compute

  compute_name  = "${var.project_id}-${each.value.hostname}"
  compute_image = var.ec2_ami
  compute_size  = var.compute_size
  zone          = "${each.value.region}-${each.value.zone}"
  region        = each.value.region
  security_groups = [aws_security_group.allow_bastion_ssh.id]

  subnet_id = module.vpc.public_subnets[0]

  ssh_user =  var.ssh_user
  key_name =  var.ssh_key_name

  metadata_startup_script = each.value.metadata_startup_script
}

module "eks" {
  source                        = "terraform-aws-modules/eks/aws"
  version = "19.19.0"
  cluster_name                  = "${var.project_id}-cluster"
  cluster_version               = "${var.kubernetes_version}"
  subnet_ids                       = module.vpc.private_subnets
  iam_role_name         = "${var.project_id}"
  cluster_enabled_log_types     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cluster_endpoint_public_access = false

  cluster_addons = {
    kube-proxy = {}
    vpc-cni    = {}
    coredns = {
      configuration_values = jsonencode({
        computeType = "Fargate"
      })
    }
  }

  # Fargate profiles use the cluster primary security group so these are not utilized
  create_node_security_group    = false

  cluster_security_group_additional_rules = {
    allow_https = {
      description                = "Allow 443 access from VPC"
      protocol                   = "tcp"
      from_port                  = 443
      to_port                    = 443
      type                       = "ingress"
      cidr_blocks = [var.vpc_cidr]
      # source_node_security_group = true
    }
  }

  vpc_id = module.vpc.vpc_id

  fargate_profiles = {
    fargate-profile = {
      selectors = [
        {
          namespace = "kube-system"
          # labels = {
          #   k8s-app = "kube-dns"
          # }
        },
        {
          namespace = "default"
        }
      ]
      subnets = flatten([module.vpc.private_subnets])
    }
  }
}

provider "kubernetes" {
  # Configuration options
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  proxy_url = "http://localhost:${data.external.bastion[0].result.port}"

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

data "external" "bastion" {
  count   = 1
  program = ["python3", "${path.module}/start_proxy.py"]
  query = {
    project  = var.project_id
    instance = module.compute["bastion"].ip_address.public_ip
    ssh_user = var.ssh_user
    ssh_private_key = var.ssh_private_key
    ssh_extra_args = var.ssh_extra_args
    host = module.eks.cluster_endpoint
  }
}

# Promtail config
resource "kubernetes_config_map" "promtail-config" {
  metadata {
    name = "promtail-config"
  }

  data = {
    "promtail.yml" = "${file("${path.module}/promtail.yml")}${file("${path.module}/promtail-lokiurl.yml")}"
  }
}

# Vouch 1
resource "kubernetes_config_map" "vouch1-config" {
  metadata {
    name = "vouch1-config"
  }

  data = {
    "vouch-ee.json" = "${file("${path.module}/config/vouch-ee.json")}"
    "vouch.yml" = "${file("${path.module}/config/vouch1.yml")}"
  }
}

resource "kubernetes_secret" "vouch1-secret" {
  metadata {
    name = "vouch1-secret"
  }

  data = {
    "vouch1.crt" = "${file("${path.module}/config/certs/vouch1.crt")}"
    "vouch1.key" = "${file("${path.module}/config/certs/vouch1.key")}"
    "dirk_authority.crt" = "${file("${path.module}/config/certs/dirk_authority.crt")}"
    "tempo_client.crt" = "${file("${path.module}/config/certs/tempo_client.crt")}"
    "tempo_client.key" = "${file("${path.module}/config/certs/tempo_client.key")}"
    "tempo_authority.crt" = "${file("${path.module}/config/certs/tempo_authority.crt")}"
  }
}

resource "kubernetes_deployment" "vouch1" {
  metadata {
    name = "vouch1"
    labels = {
      vouch = "vouch1"
      app = "vouch"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        vouch = "vouch1"
        app = "vouch"
      }
    }

    template {
      metadata {
        labels = {
          vouch = "vouch1"
          app = "vouch"
        }
      }

      spec {
        # Vouch app
        hostname = "${var.mev_subdomain}"
        container {
          image = "attestant/vouch:${var.vouch_tag}"
          name  = "vouch1"
          args = [
            "--base-dir=/config",
            "--log-file=/var/log/containers/vouch.log"
          ]

          port {
            container_port = 18550
          }

          volume_mount {
            mount_path = "/config/vouch-ee.json"
            sub_path = "vouch-ee.json"
            name       = "config"
          }
          
          volume_mount {
            mount_path = "/config/vouch.yml"
            sub_path = "vouch.yml"
            name       = "config"
          }

          volume_mount {
            mount_path = "/config/certs/vouch1.crt"
            sub_path = "vouch1.crt"
            name       = "secret"
          }

          volume_mount {
            mount_path = "/config/certs/vouch1.key"
            sub_path = "vouch1.key"
            name       = "secret"
          }

          volume_mount {
            mount_path = "/config/certs/dirk_authority.crt"
            sub_path = "dirk_authority.crt"
            name       = "secret"
          }

          volume_mount {
            mount_path = "/config/certs/tempo_client.crt"
            sub_path = "tempo_client.crt"
            name       = "secret"
          }

          volume_mount {
            mount_path = "/config/certs/tempo_client.key"
            sub_path = "tempo_client.key"
            name       = "secret"
          }

          volume_mount {
            mount_path = "/config/certs/tempo_authority.crt"
            sub_path = "tempo_authority.crt"
            name       = "secret"
          }

          volume_mount {
            mount_path = "/var/log/containers"
            name       = "app-logs"
          }

          resources {
            limits = {
              cpu    = "0.25"
              memory = "1Gi"
              ephemeral-storage = "100Mi"
            }

            requests = {
              cpu    = "0.25"
              memory = "1Gi"
              ephemeral-storage = "100Mi"
            }
          }
        }

        # Send logs to loki sidecar
        container {
          image = "grafana/promtail:latest"
          name  = "promtail"
          command = ["/bin/bash", "-c"]
          args = ["cp /promtail-config.yml /promtail.yml; sed -i \"s/LABEL_SERVER/$LABEL_SERVER/\" \"/promtail.yml\"; /usr/bin/promtail --config.file=/promtail.yml 2>&1 | tee -a /var/log/containers/promtail-vouch.log"]

          env {
            name = "LABEL_SERVER"
            value = "${var.project_id}-vouch"
          }

          volume_mount {
            mount_path = "/var/log/containers"
            name       = "app-logs"
          }
          volume_mount {
            mount_path = "/promtail-config.yml"
            sub_path = "promtail.yml"
            name       = "promtail-config"
          }

          resources {
            limits = {
              cpu    = "0.25"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "promtail-config"

          config_map {
            name = "promtail-config"
            default_mode = "0644"
          }
        }

        volume {
          name = "app-logs"
          empty_dir {}
        }

        volume {
          name = "config"

          config_map {
            name = "vouch1-config"
            default_mode = "0644"
          }
        }
        
        volume {
          name = "secret"

          secret {
            default_mode = "0644"
            secret_name = "vouch1-secret"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "vouch1-mev" {

  metadata {
    name = "vouch1-mev"
  }

  spec {
    port {
      port        = 80
      target_port = 18550
      name = "mev"
    }

    selector = {
      vouch = "vouch1"
    }

    type = "NodePort"
  }
}

resource "kubernetes_cluster_role" "traefik_role" {
  metadata {
    name = "traefik-role"
  }

  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = [""]
    resources  = ["services", "endpoints", "secrets"]
  }

  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses", "ingressclasses"]
  }

  rule {
    verbs      = ["update"]
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses/status"]
  }
}

resource "kubernetes_service_account" "traefik_account" {
  metadata {
    name = "traefik-account"
  }
}

resource "kubernetes_cluster_role_binding" "traefik_role_binding" {
  metadata {
    name = "traefik-role-binding"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "traefik-account"
    namespace = "default"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "traefik-role"
  }
}

resource "aws_efs_file_system" "traefik_pvc_efs" {
  creation_token = "traefik_pvc"
}

resource "aws_efs_mount_target" "traefik_pvc_efs_mount_target" {
  depends_on = [ module.vpc ]
  for_each = toset(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.traefik_pvc_efs.id
  subnet_id   	= each.value
  # subnet_id   	= "subnet-test"
  security_groups = [aws_security_group.allow_nfs_inbound.id]
}

resource "aws_security_group" "allow_nfs_inbound" {
  name    	  = "allow_nfs_inbound"
  description = "Allow NFS inbound traffic from provided security group"
  vpc_id  	  = module.vpc.vpc_id

  ingress {
    description 	= "NFS from VPC"
    from_port   	= 2049
    to_port     	= 2049
    protocol    	= "tcp"
    security_groups = [module.eks.cluster_primary_security_group_id]
  }
}

resource "kubernetes_persistent_volume_v1" "traefik_pv" {
  metadata {
	  name = "traefik-pv"
  }

  spec {
    capacity = {
      storage = "1Mi"
    }

    volume_mode    	= "Filesystem"
    access_modes   	= ["ReadWriteOnce"]
    storage_class_name = "gp2"

    persistent_volume_source {
      csi {
        driver    	= "efs.csi.aws.com"
        volume_handle = aws_efs_file_system.traefik_pvc_efs.id
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "traefik_pvc" {
  wait_until_bound = false

  metadata {
    name      = "traefik-pvc"
  }

  spec {
    volume_mode    	= "Filesystem"
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "1Mi"
      }
    }

    volume_name = "${kubernetes_persistent_volume_v1.traefik_pv.metadata.0.name}"
  }
}

resource "kubernetes_deployment" "traefik" {

  depends_on = [
    kubernetes_service_account.traefik_account,
    kubernetes_persistent_volume_v1.traefik_pv
  ]

  metadata {
    name = "traefik"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "traefik"
      }
    }

    template {
      metadata {
        labels = {
          app = "traefik"
        }
      }

      spec {
        service_account_name = "traefik-account"

        container {
          name  = "traefik"
          image = "traefik:latest"
          args  = [
            "--log.level=DEBUG",
            "--log.filePath=/var/log/containers/traefik.log", # Will write logs so promtail can scrape them, problem kubectl wont get any logs
            # "--certificatesResolvers.letsencrypt.acme.caServer=https://acme-staging-v02.api.letsencrypt.org/directory",
            "--providers.kubernetesingress",
            "--certificatesresolvers.letsencrypt.acme.dnschallenge=true",
            "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare",
            "--certificatesresolvers.letsencrypt.acme.email=${var.acme_email}",
            "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json",
            "--entrypoints.websecure.address=:443",
            "--entrypoints.websecure.http.tls=true",
            "--entrypoints.websecure.http.tls.certResolver=letsencrypt",
            "--metrics",
            "--metrics.prometheus"
          ]

          port {
            name           = "websecure"
            container_port = 443
          }

          env {
            name  = "CF_DNS_API_TOKEN"
            value = var.cf_api_token
          }

          volume_mount {
            mount_path = "/letsencrypt"
            name      = "traefik-certs"
          }

          volume_mount {
            mount_path = "/var/log/containers"
            name       = "app-logs"
          }

          resources {
            limits = {
              cpu    = "0.25"
              memory = "0.5Gi"
              ephemeral-storage = "10Mi"
            }

            requests = {
              cpu    = "0.25"
              memory = "0.5Gi"
              ephemeral-storage = "10Mi"
            }
          }
        }

        # Send logs to loki sidecar
        container {
          image = "grafana/promtail:latest"
          name  = "promtail"
          command = ["/bin/bash", "-c"]
          args = ["cp /promtail-config.yml /promtail.yml; sed -i \"s/LABEL_SERVER/$LABEL_SERVER/\" \"/promtail.yml\"; /usr/bin/promtail --config.file=/promtail.yml 2>&1 | tee -a /var/log/containers/promtail-traefik.log"]

          env {
            name = "LABEL_SERVER"
            value = "${var.project_id}-vouch"
          }

          volume_mount {
            mount_path = "/var/log/containers"
            name       = "app-logs"
          }
          volume_mount {
            mount_path = "/promtail-config.yml"
            sub_path = "promtail.yml"
            name       = "promtail-config"
          }

          resources {
            limits = {
              cpu    = "0.25"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "promtail-config"

          config_map {
            name = "promtail-config"
            default_mode = "0644"
          }
        }
        
        volume {
          name = "app-logs"
          empty_dir {}
        }

        volume {
          name = "traefik-certs"
          persistent_volume_claim {
            claim_name = "traefik-pvc"
          }
        }
      }
    }

    strategy {
      type = "Recreate"
    }
  }
}

resource "kubernetes_service" "traefik_service" {

  metadata {
    name = "traefik-service"

    annotations = {
      "external-dns.alpha.kubernetes.io/hostname" = "${var.mev_subdomain}.${var.cf_domain}"
      "external-dns.alpha.kubernetes.io/ttl" = 120
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
      "service.beta.kubernetes.io/aws-load-balancer-type" = "external"
      "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
      "service.beta.kubernetes.io/aws-load-balancer-target-group-attributes" = "preserve_client_ip.enabled=true"
    }
  }

  spec {
    port {
      protocol    = "TCP"
      port        = 443
      target_port = 443
      name = "websecure"
    }

    selector = {
      app = "traefik"
    }

    type = "LoadBalancer"

    load_balancer_source_ranges = concat(var.vouch_https_in_addresses, formatlist("%s/32", module.vpc.nat_public_ips))
  }
}

resource "kubernetes_ingress_v1" "vouch_ingress" {
  metadata {
    name = "vouch-ingress"
    annotations = {
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
    }
  }

  spec {
    rule {
      host = "${var.mev_subdomain}.${var.cf_domain}"
      http {
        path {
          backend {
            service {
              name = "vouch1-mev"

              port {
                name = "mev"
              }
            }
          }
        }

        # path {
        #   backend {
        #     service {
        #       name = "whoami"
        #       port {
        #         name = "http"
        #       }
        #     }
        #   }

        #   path = "/foo"
        # }
      }
    }
  }
}

# Prometheus
resource "kubernetes_config_map" "prometheus-config" {
  metadata {
    name = "prometheus-config"
  }

  data = {
    "prometheus.yml" = "${file("${path.module}/prometheus.yml")}${file("${path.module}/prometheus-custom.yml")}"
  }
}

resource "kubernetes_deployment" "prometheus" {
  metadata {
    name = "prometheus"
    labels = {
      app = "prometheus"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "prometheus"
      }
    }

    template {
      metadata {
        labels = {
          app = "prometheus"
        }
      }

      spec {
        container {
          image = "prom/prometheus:latest"
          name  = "prometheus"

          volume_mount {
            mount_path = "/etc/prometheus/prometheus.yml"
            name       = "config"
            sub_path = "prometheus.yml"
          }
        }

        volume {
          name = "config"

          config_map {
            name = "prometheus-config"
            default_mode = "0644"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "vouch_metrics" {

  metadata {
    name = "vouch-metrics"
  }

  spec {
    port {
      name        = "vouch-metrics"
      port        = 8081
    }

    selector = {
      app = "vouch"
    }

    type = "NodePort"
  }
}

resource "kubernetes_service" "traefik_metrics" {

  metadata {
    name = "traefik-metrics"
  }

  spec {
    port {
      name        = "traefik-metrics"
      port        = 8080
    }

    selector = {
      app = "traefik"
    }

    type = "NodePort"
  }
}

output "kubernetes_cluster_name" {
  value = module.eks.cluster_name
}

output "kubernetes_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubernetes_cluster_arn" {
  value = module.eks.cluster_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "aws_account_id" {
  value = module.vpc.vpc_owner_id
}

output "vpc_nat_public_ips" {
  value = module.vpc.nat_public_ips
}

output "compute_addresses" {
  value = {
    for key,value in module.compute: key => value.ip_address.public_ip
  }
}

output "lb_controller_policy_name" {
  value = aws_iam_policy.aws_load_balancer_controller_policy.name
}

output "cluster_primary_security_group_id" {
  value = module.eks.cluster_primary_security_group_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}
