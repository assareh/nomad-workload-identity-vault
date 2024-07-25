output "info" {
  description = "Helpful information on where to find logs"
  value = <<EOT
You can view the bootstrap logs with:
    tail -f /var/log/user-data.log

You can view the Vault audit logs with:
    sudo tail -f /var/log/vault_audit.log | jq
EOT
}

output "nomad_client_ssh" {
  description = "SSH command for the Nomad Client"
  value = "ssh -i ${local.private_key_filename} -o IdentitiesOnly=yes ubuntu@${aws_instance.nomad-client.public_ip}"
}

output "nomad_server_http" {
  description = "HTTP address of the Nomad Server UI"
  value = "http://${aws_instance.nomad-server.public_ip}:4646"
}

output "nomad_server_ssh" {
  description = "SSH command for the Nomad Server"
  value = "ssh -i ${local.private_key_filename} -o IdentitiesOnly=yes ubuntu@${aws_instance.nomad-server.public_ip}"
}

# uncomment this if you are using HCP Terraform
# output "ssh_key" {
#   description = "SSH key to save as aws-ssh-key.pem"
#   value = nonsensitive(tls_private_key.aws_ssh_key.private_key_pem)
# }

output "vault_server_http" {
  description = "HTTP address of the Vault Server UI"
  value = "https://${aws_instance.vault-server.public_ip}:8200"
}

output "vault_server_ssh" {
  description = "SSH command for the Vault Server"
  value = "ssh -i ${local.private_key_filename} -o IdentitiesOnly=yes ubuntu@${aws_instance.vault-server.public_ip}"
}

