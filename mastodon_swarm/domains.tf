

resource "digitalocean_record" "manager_records" {
  count  = "${var.swarm_manager_count}"
  
  domain = "${var.domain_name}"
  type   = "A"
  name   = "${format("%s-%02d.%s", "${var.manager_name}", count.index + 1, var.digitalocean_region)}"
  value  = "${module.swarm-cluster.manager_ips[count.index]}"
}

resource "digitalocean_record" "worker_records" {
  count  = "${var.swarm_worker_count}"
  
  domain = "${var.domain_name}"
  type   = "A"
  name   = "${format("%s-%02d.%s", "${var.worker_name}", count.index + 1, var.digitalocean_region)}"
  value  = "${module.swarm-cluster.worker_ips[count.index]}"
}

resource "digitalocean_record" "swarm_fe_round_robin" {
  depends_on = ["module.swarm-cluster"]
  count  = "${var.swarm_manager_count + var.swarm_worker_count}"
  
  domain = "${var.domain_name}"
  type   = "A"
  name   = "${local.swarm_hostname == var.domain_name ? "@" : var.subdomain}"
  value  = "${local.all_swarm_ips[count.index]}"
}

resource "digitalocean_record" "www_cname" {
  domain = "${var.domain_name}"
  type   = "CNAME"
  name   = "${var.subdomain != "" ? "www.${var.subdomain}" : "www"}"
  value  = "${local.swarm_hostname == var.domain_name ? "${var.domain_name}." : "${local.swarm_hostname}."}"
}
