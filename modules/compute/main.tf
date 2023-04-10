resource "aws_instance" "default" {
  instance_type = var.compute_size

  tags = {
    Name = var.compute_name
  }

  ami = var.compute_image
  user_data = var.metadata_startup_script
  key_name = var.key_name
  vpc_security_group_ids = var.security_groups
  subnet_id = var.subnet_id
}

resource "aws_eip" "ip_address" {
  vpc = true

  instance                  = aws_instance.default.id
  # associate_with_private_ip = "10.0.0.12"
  # depends_on                = [aws_internet_gateway.gw]
}
