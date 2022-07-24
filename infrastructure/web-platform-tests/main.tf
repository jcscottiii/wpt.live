locals {
  bucket_name = "${var.name}-certificates"

  update_policy = {
      type           = "PROACTIVE"
      minimal_action = "RESTART"
      # > maxUnavailable must be greater than 0 when minimal action is set to
      # > RESTART
      max_unavailable_fixed = 1
  }

}

module "wpt-server-container" {
  source = "terraform-google-modules/container-vm/google"
  version = "~> 2.0"

  container = {
    image = var.wpt_server_image
    env = [
      {
        name  = "WPT_HOST"
        value = var.host_name
      },
      {
        name  = "WPT_ALT_HOST"
        value = var.alt_host_name
      },
      {
        name  = "WPT_BUCKET"
        value = local.bucket_name
      },
    ]
  }

  restart_policy = "Always"
}

module "cert-renewer-container" {
  source = "terraform-google-modules/container-vm/google"
  version = "~> 2.0"

  container = {
    image = var.cert_renewer_image
    env = [
      {
        name  = "WPT_HOST"
        value = var.host_name
      },
      {
        name  = "WPT_ALT_HOST"
        value = var.alt_host_name
      },
      {
        name  = "WPT_BUCKET"
        value = local.bucket_name
      },
    ]
  }

  restart_policy = "Always"
}

resource "google_compute_health_check" "wpt_health_check" {
  name    = "${var.name}-wpt-servers"

  check_interval_sec  = 10
  timeout_sec         = 10
  healthy_threshold   = 3
  unhealthy_threshold = 6

  https_health_check {
    port         = "443"
  # A query parameter is used to distinguish the health check in the server's
  # request logs.
    request_path = "/?gcp-health-check"
  }
}

resource "google_compute_instance_group_manager" "wpt_servers" {
  name = "${var.name}-wpt-servers"
  zone = "${var.zone}"
  description        = "compute VM Instance Group"
  wait_for_instances = false
  base_instance_name = "${var.name}-wpt-servers"
  version {
    name              = "${var.name}-wpt-servers-default"
    instance_template = google_compute_instance_template.wpt_server.id
  }
  update_policy {
    type = local.update_policy.type
    minimal_action = local.update_policy.minimal_action
    max_unavailable_fixed  = local.update_policy.max_unavailable_fixed
  }
  target_pools = [google_compute_target_pool.default.self_link]
  target_size  = 2

  named_port {
    name = "http-primary"
    port = 80
  }

  named_port {
    name = "http-secondary"
    port = 8000
  }

  named_port {
    name = "https"
    port = 443
  }

  named_port {
    name = "http2"
    port = 8001
  }

  named_port {
    name = "websocket"
    port = 8002
  }

  named_port {
    name = "websocket-secure"
    port = 8003
  }

  named_port {
    name = "https-secondary"
    port = 8443
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.wpt_health_check.self_link
    initial_delay_sec = 30
  }
}

resource "google_compute_firewall" "wpt-servers-default-ssh" {
  name    = "${var.name}-wpt-servers-vm-ssh"
  network = "${var.network_name}"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh"]
}

resource "google_compute_instance_template" "wpt_server" {
  name_prefix        = "default-"
  description = "This template is used to create wpt-server instances."

  tags = ["allow-ssh", "${var.name}-allow"]

  # As of 2020-06-17, we were running into OOM issues with the 1.7 GB
  # "g1-small" instance[1]. This was suspected to be due to 'git gc' needing
  # more memory, so we upgraded to "e2-medium" (4 GB of RAM).
  #
  # [1] https://github.com/web-platform-tests/wpt.live/issues/30
  machine_type = "e2-medium"

  # The "google-logging-enabled" metadata is undocumented, but it is apparently
  # necessary to enable the capture of logs from the Docker image.
  #
  # https://github.com/GoogleCloudPlatform/konlet/issues/56
  labels = {
    "container-vm" = module.wpt-server-container.vm_container_label
  }

  network_interface {
    network = "${var.network_name}"
    subnetwork         = "${var.subnetwork_name}"
    access_config {
      network_tier = "PREMIUM"
    }
  }

  can_ip_forward       = false

  // Create a new boot disk from an image
  disk {
    auto_delete       = true
    boot              = true
    source_image      = "${module.wpt-server-container.source_image}"
    type =   "PERSISTENT"
    disk_type = "pd-ssd"
    disk_size_gb = var.wpt_server_disk_size
    mode = "READ_WRITE"
  }

  service_account {
    email  = "default"
    scopes = ["storage-ro", "logging-write"]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  metadata = {
    "gce-container-declaration" = module.wpt-server-container.metadata_value
    "startup-script" = ""
    "tf_depends_id" = ""
    "google-logging-enabled" = "true"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_template" "cert_renewers" {
  name_prefix = "default-"

  machine_type = "f1-micro"

  region = "${var.region}"

  tags = ["allow-ssh", "${var.name}-allow"]

  labels = {
    "container-vm" = module.cert-renewer-container.vm_container_label
  }

  network_interface {
    network            = "${var.network_name}"
    subnetwork         = "${var.subnetwork_name}"
    network_ip         = ""
    access_config {
      network_tier = "PREMIUM"
    }
  }

  can_ip_forward = false

  disk {
    auto_delete  = true
    boot         = true
    source_image = "${module.cert-renewer-container.source_image}"
    type         = "PERSISTENT"
    disk_type    = "pd-ssd"
    mode         = "READ_WRITE"
  }

  service_account {
    email  = "default"
    scopes = ["cloud-platform"]
  }

  metadata = {
    "gce-container-declaration" = module.cert-renewer-container.metadata_value
    "startup-script" = ""
    "tf_depends_id" = ""
    "google-logging-enabled" = "true"
  }

  scheduling {
    preemptible       = false
    automatic_restart = true
    on_host_maintenance = "MIGRATE"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_instance_group_manager" "cert_renewers" {
  name               = "${var.name}-cert-renewers"
  description        = "compute VM Instance Group"
  wait_for_instances = false

  base_instance_name = "${var.name}-cert-renewers"

  version {
    instance_template = "${google_compute_instance_template.cert_renewers.self_link}"
  }

  zone = "${var.zone}"

  update_policy {
    # The type is different from wpt servers's update policy.
    type = "OPPORTUNISTIC"
    minimal_action = local.update_policy.minimal_action
    max_unavailable_fixed  = local.update_policy.max_unavailable_fixed
  }

  target_pools = []

  target_size = 1

  named_port {
    name = "http"
    port = 8004
  }

}

resource "google_storage_bucket" "certificates" {
  name = local.bucket_name
  location = "US"
}

