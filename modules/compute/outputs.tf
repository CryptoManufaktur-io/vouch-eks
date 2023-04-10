output "ip_address" {
    value = aws_eip.ip_address
}

output "instance" {
    value = aws_instance.default
}
