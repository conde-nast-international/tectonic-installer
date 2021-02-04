module "bootkube" {
  source         = "../../modules/bootkube"
  cloud_provider = "aws"

  cluster_name = "${var.tectonic_cluster_name}"

  kube_apiserver_url = "https://${var.tectonic_aws_private_endpoints ? module.dns.api_internal_fqdn : module.dns.api_external_fqdn}:443"
  oidc_issuer_url    = "https://cluster-auth.${var.tectonic_base_domain}/identity"

  # Platform-independent variables wiring, do not modify.
  container_images = "${var.tectonic_container_images}"
  versions         = "${var.tectonic_versions}"
  self_hosted_etcd = "${var.tectonic_self_hosted_etcd}"

  service_cidr = "${var.tectonic_service_cidr}"
  cluster_cidr = "${var.tectonic_cluster_cidr}"

  advertise_address = "0.0.0.0"
  anonymous_auth    = "false"

  oidc_username_claim = "email"
  oidc_groups_claim   = "groups"
  oidc_client_id      = "k8s-auth"
  oidc_ca_cert        = "${module.ingress_certs.ca_cert_pem}"

  apiserver_cert_pem   = "${module.kube_certs.apiserver_cert_pem}"
  apiserver_key_pem    = "${module.kube_certs.apiserver_key_pem}"
  etcd_ca_cert_pem     = "${module.etcd_certs.etcd_ca_crt_pem}"
  etcd_client_cert_pem = "${module.etcd_certs.etcd_client_crt_pem}"
  etcd_client_key_pem  = "${module.etcd_certs.etcd_client_key_pem}"
  etcd_peer_cert_pem   = "${module.etcd_certs.etcd_peer_crt_pem}"
  etcd_peer_key_pem    = "${module.etcd_certs.etcd_peer_key_pem}"
  etcd_server_cert_pem = "${module.etcd_certs.etcd_server_crt_pem}"
  etcd_server_key_pem  = "${module.etcd_certs.etcd_server_key_pem}"
  kube_ca_cert_pem     = "${module.kube_certs.ca_cert_pem}"
  kubelet_cert_pem     = "${module.kube_certs.kubelet_cert_pem}"
  kubelet_key_pem      = "${module.kube_certs.kubelet_key_pem}"

  etcd_backup_size          = "${var.tectonic_etcd_backup_size}"
  etcd_backup_storage_class = "${var.tectonic_etcd_backup_storage_class}"
  etcd_endpoints            = "${module.dns.etcd_endpoints}"
  master_count              = "${var.tectonic_master_count}"

  # The default behavior of Kubernetes's controller manager is to mark a node
  # as Unhealthy after 40s without an update from the node's kubelet. However,
  # AWS ELB's Route53 records have a fixed TTL of 60s. Therefore, when an ELB's
  # node disappears (e.g. scaled down or crashed), kubelet might fail to report
  # for a period of time that exceed the default grace period of 40s and the
  # node might become Unhealthy. While the eviction process won't start until
  # the pod_eviction_timeout is reached, 5min by default, certain operators
  # might already have taken action. This is the case for the etcd operator as
  # of v0.3.3, which removes the likely-healthy etcd pods from the the
  # cluster, potentially leading to a loss-of-quorum as generally all kubelets
  # are affected simultaneously.
  #
  # To cope with this issue, we increase the grace period, and reduce the
  # pod eviction time-out accordingly so pods still get evicted after an total
  # time of 340s after the first post-status failure.
  #
  # Ref: https://github.com/kubernetes/kubernetes/issues/41916
  # Ref: https://github.com/kubernetes-incubator/kube-aws/issues/598
  node_monitor_grace_period = "2m"

  pod_eviction_timeout = "220s"

  cloud_config_path = ""
}

module "vpc" {
  source = "../../modules/aws/cnid-vpc"

  base_domain              = "${var.tectonic_base_domain}"
  cidr_block               = "${var.tectonic_aws_vpc_cidr_block}"
  cluster_id               = "${module.tectonic.cluster_id}"
  cluster_name             = "${var.tectonic_cluster_name}"
  custom_dns_name          = "${var.tectonic_dns_name}"
  enable_etcd_sg           = "${var.tectonic_self_hosted_etcd == "" && length(compact(var.tectonic_etcd_servers)) == 0 ? 1 : 0}"
  external_master_subnets  = "${compact(var.tectonic_aws_external_master_subnet_ids)}"
  external_vpc_id          = "${var.tectonic_aws_external_vpc_id}"
  external_worker_subnets  = "${compact(var.tectonic_aws_external_worker_subnet_ids)}"
  extra_tags               = "${var.tectonic_aws_extra_tags}"
  private_master_endpoints = "${var.tectonic_aws_private_endpoints}"
  public_master_endpoints  = "${var.tectonic_aws_public_endpoints}"

  # VPC layout settings.
  #
  # The following parameters control the layout of the VPC accross availability zones.
  # Two modes are available:
  # A. Explicitly configure a list of AZs + associated subnet CIDRs
  # B. Let the module calculate subnets accross a set number of AZs
  #
  # To enable mode A, configure a set of AZs + CIDRs for masters and workers using the
  # "tectonic_aws_master_custom_subnets" and "tectonic_aws_worker_custom_subnets" variables.
  #
  # To enable mode B, make sure that "tectonic_aws_master_custom_subnets" and "tectonic_aws_worker_custom_subnets"
  # ARE NOT SET.

  # These counts could be deducted by length(keys(var.tectonic_aws_master_custom_subnets))
  # but there is a restriction on passing computed values as counts. This approach works around that.
  master_az_count = "${length(keys(var.tectonic_aws_master_custom_subnets)) > 0 ? "${length(keys(var.tectonic_aws_master_custom_subnets))}" : "${length(data.aws_availability_zones.azs.names)}"}"
  worker_az_count = "${length(keys(var.tectonic_aws_worker_custom_subnets)) > 0 ? "${length(keys(var.tectonic_aws_worker_custom_subnets))}" : "${length(data.aws_availability_zones.azs.names)}"}"
  # The appending of the "padding" element is required as workaround since the function
  # element() won't work on empty lists. See https://github.com/hashicorp/terraform/issues/11210
  master_subnets = "${concat(values(var.tectonic_aws_master_custom_subnets),list("padding"))}"
  worker_subnets = "${concat(values(var.tectonic_aws_worker_custom_subnets),list("padding"))}"
  # The split() / join() trick works around the limitation of ternary operator expressions
  # only being able to return strings.
  master_azs = "${ split("|", "${length(keys(var.tectonic_aws_master_custom_subnets))}" > 0 ?
    join("|", keys(var.tectonic_aws_master_custom_subnets)) :
    join("|", data.aws_availability_zones.azs.names)
  )}"
  worker_azs = "${ split("|", "${length(keys(var.tectonic_aws_worker_custom_subnets))}" > 0 ?
    join("|", keys(var.tectonic_aws_worker_custom_subnets)) :
    join("|", data.aws_availability_zones.azs.names)
  )}"
  # This will restrict access kube apiserver
  # more info: https://confluence.condenastint.com/pages/viewpage.action?spaceKey=PLAT&title=Networking
  # more info: https://confluence.condenastint.com/display/PLAT/Private+Network+IP+Ranges
  master_sg_ingress_cidr = [
    "10.16.0.0/16",      # This will ensure communication between masters and workers
    "18.194.85.57/32",   # Deployment NAT staging (staging kubernetes cluster): this will allow concourse to deploy
    "18.196.44.134/32",
    "18.196.58.25/32",
    "34.249.24.51/32",   # Deployment NAT dev: This will allow circleci dev to have access to cluster
    "34.254.81.66/32",
    "52.210.167.47/32",
    "34.255.61.149/32",  # Deploy dev EIPs: Whitelist Aviatrix Dev VPN
    "52.19.163.93/32",
    "63.33.147.183/32",
    "34.248.88.182/32",  # Deploy-prod NAT gateways(circle ci): CircleCI Enterprise for access to services
    "52.211.27.219/32",
    "63.34.89.192/32",
    "18.202.116.116/32", # Deploy prod EIPs: Whitelist Aviatrix Prod VPN
    "63.32.174.222/32",
    "63.33.132.82/32",
  ]
  # master ssh access from VPN only
  # more info: https://confluence.condenastint.com/pages/viewpage.action?spaceKey=PLAT&title=Networking
  master_sg_ssh_ingress_cidr = [
    "18.202.116.116/32", # Deploy prod EIPs: Whitelist Aviatrix Prod VPN
    "63.32.174.222/32",
    "63.33.132.82/32",
    "34.255.61.149/32",  # Deploy dev EIPs: Whitelist Aviatrix Dev VPN
    "52.19.163.93/32",
    "63.33.147.183/32",
    "10.16.0.0/20",      # Allows SSH to master over private IP
    "10.16.16.0/20",
    "10.16.32.0/20",
  ]
  # To allow access from masters to workers using ssh jump
  # Kubernetes subnets
  worker_sg_ssh_ingress_cidr = [
    "10.16.0.0/20",  # k8s-eu-master-eu-central-1a
    "10.16.16.0/20", # k8s-eu-master-eu-central-1b
    "10.16.32.0/20", # k8s-eu-master-eu-central-1c
  ]
}

output "vpc_id" {
  value = "${module.vpc.vpc_id}"
}

output "vpc_cidr_block" {
  value = "${var.tectonic_aws_vpc_cidr_block}"
}

output "vpc_subnet_ids" {
  value = "${list(module.vpc.worker_subnet_ids, module.vpc.master_subnet_ids)}"
}
