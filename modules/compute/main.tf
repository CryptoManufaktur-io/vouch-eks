resource "google_compute_address" "ip_address" {
  name = "${var.compute_name}-ip"
  region = var.region
}

resource "google_compute_instance" "default" {
  name         = var.compute_name
  machine_type = var.compute_size
  zone         = var.zone

  tags = var.tags

  boot_disk {
    initialize_params {
      image = var.compute_image
    }
  }

  network_interface {
    network = var.network
    subnetwork = var.subnetwork
    access_config {
      nat_ip = google_compute_address.ip_address.address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${file(var.ssh_pub_key)}"
    startup-script = var.metadata_startup_script
  }

  # provisioner "file" {
  #   source      = var.dir_provisioner.source
  #   destination = var.dir_provisioner.destination
  #   connection {
  #     host = "${google_compute_instance.default.network_interface.0.access_config.0.nat_ip}"
  #     type = "ssh"
  #     user = var.ssh_user
  #     private_key = "${file(var.ssh_private_key)}"
  #   }
  # }
}