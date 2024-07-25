#!/usr/bin/env bash
set -x
exec > >(tee /var/log/user-data.log|logger -t user-data ) 2>&1

logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo "$DT $0: $1"
}

logger "Running"

##--------------------------------------------------------------------
## Variables

# Get Private IP address
PRIVATE_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)

AWS_REGION="${aws_region}"
KMS_KEY="${kms_key}"

# Detect package management system.
YUM=$(which yum 2>/dev/null)
APT_GET=$(which apt-get 2>/dev/null)

##--------------------------------------------------------------------
## Functions

user_rhel() {
  # RHEL/CentOS user setup
  sudo /usr/sbin/groupadd --force --system $${USER_GROUP}

  if ! getent passwd $${USER_NAME} >/dev/null ; then
    sudo /usr/sbin/adduser \
      --system \
      --gid $${USER_GROUP} \
      --home $${USER_HOME} \
      --no-create-home \
      --comment "$${USER_COMMENT}" \
      --shell /bin/false \
      $${USER_NAME}  >/dev/null
  fi
}

user_ubuntu() {
  # UBUNTU user setup
  if ! getent group $${USER_GROUP} >/dev/null
  then
    sudo addgroup --system $${USER_GROUP} >/dev/null
  fi

  if ! getent passwd $${USER_NAME} >/dev/null
  then
    sudo adduser \
      --system \
      --disabled-login \
      --ingroup $${USER_GROUP} \
      --home $${USER_HOME} \
      --no-create-home \
      --gecos "$${USER_COMMENT}" \
      --shell /bin/false \
      $${USER_NAME}  >/dev/null
  fi
}

##--------------------------------------------------------------------
## Install Base Prerequisites

logger "Setting timezone to UTC"
sudo timedatectl set-timezone UTC

if [[ ! -z $${YUM} ]]; then
  logger "RHEL/CentOS system detected"
  logger "Performing updates and installing prerequisites"
  sudo yum-config-manager --enable rhui-REGION-rhel-server-releases-optional
  sudo yum-config-manager --enable rhui-REGION-rhel-server-supplementary
  sudo yum-config-manager --enable rhui-REGION-rhel-server-extras
  sudo yum -y check-update
  sudo yum install -q -y wget unzip bind-utils ruby rubygems ntp jq docker.io
  sudo systemctl start ntpd.service
  sudo systemctl enable ntpd.service
elif [[ ! -z $${APT_GET} ]]; then
  logger "Debian/Ubuntu system detected"
  logger "Performing updates and installing prerequisites"
  sudo apt-get -qq -y update
  sudo apt-get install -qq -y wget unzip dnsutils ruby rubygems ntp jq docker.io
  sudo systemctl start ntp.service
  sudo systemctl enable ntp.service
  logger "Disable reverse dns lookup in SSH"
  sudo sh -c 'echo "\nUseDNS no" >> /etc/ssh/sshd_config'
  sudo service ssh restart
else
  logger "Prerequisites not installed due to OS detection failure"
  exit 1;
fi


##--------------------------------------------------------------------
## Configure Vault user

USER_NAME="vault"
USER_COMMENT="HashiCorp Vault user"
USER_GROUP="vault"
USER_HOME="/srv/vault"

if [[ ! -z $${YUM} ]]; then
  logger "Setting up user $${USER_NAME} for RHEL/CentOS"
  user_rhel
elif [[ ! -z $${APT_GET} ]]; then
  logger "Setting up user $${USER_NAME} for Debian/Ubuntu"
  user_ubuntu
else
  logger "$${USER_NAME} user not created due to OS detection failure"
  exit 1;
fi

##--------------------------------------------------------------------
## Install Vault

logger "Installing Vault"
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install -y vault

logger "/usr/bin/vault --version: $(/usr/bin/vault --version)"

logger "Configuring Vault"

sudo tee /etc/vault.d/vault.hcl <<EOF
# Full configuration options can be found at https://www.vaultproject.io/docs/configuration

ui=true

disable_mlock = true

storage "raft" {
  path = "/opt/vault/data"
  node_id = "raft_node_1"
}

api_addr = "https://127.0.0.1:8200"

cluster_addr = "https://127.0.0.1:8201"

listener "tcp" {
  address                  = "0.0.0.0:8200"
  tls_cert_file            = "/opt/vault/tls/tls.crt"
  tls_key_file             = "/opt/vault/tls/tls.key"
  tls_disable_client_certs = "true"
}

seal "awskms" {
  region = "$${AWS_REGION}"
  kms_key_id = "$${KMS_KEY}"
}
EOF

sudo chown -R vault:vault /etc/vault.d /etc/ssl/vault
sudo chmod -R 0644 /etc/vault.d/*

sudo tee -a /etc/environment <<EOF
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true
EOF

source /etc/environment

logger "Granting mlock syscall to vault binary"
sudo setcap cap_ipc_lock=+ep /usr/bin/vault

sudo systemctl enable vault
sudo systemctl start vault

vault status
# Wait until vault status serves the request and responds that it is sealed
while [[ $? -ne 2 ]]; do sleep 1 && vault status; done

##--------------------------------------------------------------------
## Configure Vault
##--------------------------------------------------------------------

##-------------------------------------------------------------------
#write out current crontab
crontab -l > mycron
#echo new cron into cron file
echo "00 * * * * systemctl restart vault" >> mycron
echo "30 * * * * systemctl restart vault" >> mycron
#install new cron file
crontab mycron
rm mycron

# NOT SUITABLE FOR PRODUCTION USE
export VAULT_TOKEN="$(vault operator init -format json | jq -r '.root_token')"
sudo cat >> /etc/environment <<EOF
export VAULT_TOKEN=$${VAULT_TOKEN}
EOF

logger "Setting VAULT_ADDR and VAULT_TOKEN"
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_TOKEN=$VAULT_TOKEN

sudo touch /var/log/vault_audit.log
sudo chown vault:vault /var/log/vault_audit.log
vault audit enable file file_path=/var/log/vault_audit.log

# configure auth for nomad
logger "Configuring auth for Nomad"
vault auth enable -path=jwt-nomad jwt
ACCESSOR=$(vault auth list -format=json | jq -r ".[].accessor" | head -1)

# doc ref https://developer.hashicorp.com/nomad/docs/integrations/vault/acl
cat << EOF > /home/ubuntu/auth-method.json
{
  "jwks_url": "http://${nomad_server_addr}:4646/.well-known/jwks.json",
  "jwt_supported_algs": ["RS256", "EdDSA"],
  "default_role": "nomad-workloads"
}
EOF
vault write auth/jwt-nomad/config @/home/ubuntu/auth-method.json

# note i've removed the nomad_job_id claim for this default general role
cat << EOF > /home/ubuntu/acl-role.json
{
  "role_type": "jwt",
  "bound_audiences": ["vault.io"],
  "bound_claims": {
     "nomad_namespace": "default"
  },
  "user_claim": "/nomad_job_id",
  "user_claim_json_pointer": true,
  "claim_mappings": {
    "nomad_namespace": "nomad_namespace",
    "nomad_job_id": "nomad_job_id",
    "nomad_task": "nomad_task"
  },
  "token_type": "service",
  "token_policies": ["nomad-workloads"],
  "token_period": "30m",
  "token_explicit_max_ttl": 0
}
EOF
vault write auth/jwt-nomad/role/nomad-workloads @/home/ubuntu/acl-role.json

cat << EOF > /home/ubuntu/acl-policy.hcl
path "secret/data/{{identity.entity.aliases.$ACCESSOR.metadata.nomad_namespace}}/{{identity.entity.aliases.$ACCESSOR.metadata.nomad_job_id}}/*" {
  capabilities = ["read"]
}

path "secret/data/{{identity.entity.aliases.$ACCESSOR.metadata.nomad_namespace}}/{{identity.entity.aliases.$ACCESSOR.metadata.nomad_job_id}}" {
  capabilities = ["read"]
}

path "secret/metadata/{{identity.entity.aliases.$ACCESSOR.metadata.nomad_namespace}}/*" {
  capabilities = ["list"]
}

path "secret/metadata/*" {
  capabilities = ["list"]
}
EOF
vault policy write nomad-workloads /home/ubuntu/acl-policy.hcl

vault secrets enable -version=2 -path=secret kv
vault kv put secret/default/mongo/config root_password=password