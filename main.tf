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
      }
    }

    template {
      metadata {
        labels = {
          vouch = "vouch1"
        }
      }

      spec {
        # Vouch app
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
            mount_path = "/var/log/containers"
            name       = "app-logs"
          }

          resources {
            limits = {
              cpu    = "1"
              memory = "2Gi"
            }

            requests = {
              cpu    = "1"
              memory = "2Gi"
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

resource "kubernetes_service_account" "external_dns" {

  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_cluster_role" "external_dns" {

  metadata {
    name = "external-dns"
  }

  rule {
    verbs      = ["get", "watch", "list"]
    api_groups = [""]
    resources  = ["services", "endpoints", "pods"]
  }

  rule {
    verbs      = ["get", "watch", "list"]
    api_groups = ["extensions", "networking.k8s.io"]
    resources  = ["ingresses"]
  }
  
  rule {
    verbs      = ["get", "watch", "list"]
    api_groups = [""]
    resources  = ["endpoints"]
  }
  

  rule {
    verbs      = ["list", "watch"]
    api_groups = [""]
    resources  = ["nodes"]
  }
}

resource "kubernetes_cluster_role_binding" "external_dns_viewer" {

  metadata {
    name = "external-dns-viewer"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "external-dns"
    namespace = "default"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "external-dns"
  }
}

resource "kubernetes_deployment" "external_dns" {

  metadata {
    name = "external-dns"
  }

  spec {
    selector {
      match_labels = {
        app = "external-dns"
      }
    }

    template {
      metadata {
        labels = {
          app = "external-dns"
        }
      }

      spec {
        container {
          name  = "external-dns"
          image = "registry.k8s.io/external-dns/external-dns:v0.13.2"
          args  = ["--source=service", "--source=ingress", "--domain-filter=${var.cf_domain}", "--provider=cloudflare", "--registry=txt", "--txt-owner-id=${var.mev_subdomain}"]

          env {
            name  = "CF_API_KEY"
            value = var.cf_api_key
          }

          env {
            name  = "CF_API_EMAIL"
            value = var.cf_api_email
          }
        }

        service_account_name = "external-dns"
      }
    }

    strategy {
      type = "Recreate"
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

resource "kubernetes_deployment" "traefik" {

  depends_on = [
    kubernetes_service_account.traefik_account
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
        
        # Traefik App
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
            name  = "CLOUDFLARE_API_KEY"
            value = var.cf_api_key
          }

          env {
            name  = "CLOUDFLARE_EMAIL"
            value = var.cf_api_email
          }

          volume_mount {
            mount_path = "/var/log/containers"
            name       = "app-logs"
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
      vouch = "vouch1"
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
      traefik = "traefik"
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
