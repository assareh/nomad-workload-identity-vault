# nomad-workload-identity-vault

This repo contains a simple example of Nomad's Workload Identity being used to fetch secrets from Vault. This terraform code will create three virtual machines in AWS:
- Vault server
- Nomad server
- Nomad client

Each machine is bootstrapped with a userdata script (see the [templates](./templates) folder in this repo), so please allow time after Terraform completes for the config scripts to complete. Each host logs the userdata script to `/var/log/user-data.log`. The Vault root token can be found towards the bottom of the userdata log on the Vault server node. The Vault audit logs are available on the Vault server node at `/var/log/vault_audit.log`.

Before provisioning with Terraform please take a look at the [variables.tf](./variables.tf).

To see this in action, run [mongo.nomad](./mongo.nomad). 

## Docs
- https://developer.hashicorp.com/nomad/docs/concepts/workload-identity
- https://developer.hashicorp.com/nomad/docs/integrations/vault?page=integrations&page=vault-integration
- https://developer.hashicorp.com/nomad/docs/integrations/vault/acl
- https://developer.hashicorp.com/nomad/docs/job-specification/identity#workload-identities-for-vault