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
## Install Nomad

logger "Installing Nomad"
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install -y nomad

logger "/usr/bin/nomad --version: $(/usr/bin/nomad --version)"

logger "Configuring Nomad"

sudo tee /etc/nomad.d/nomad.hcl <<EOF
# Full configuration options can be found at https://www.nomadproject.io/docs/configuration

bind_addr = "0.0.0.0"

data_dir = "/opt/nomad"

leave_on_terminate = true  

log_level = "INFO" 

client {
  enabled    = true
  servers = ["${nomad_server_addr}:4647"]
}

server {
  enabled = false
}

vault {
  enabled = true

  # needed for enterprise
  # name = "enter vault cluster name here" see docs 

  address = "https://${vault_server_addr}:8200"

  create_from_role = "nomad-workloads"

  jwt_auth_backend_path = "jwt-nomad"

  tls_skip_verify = true
}
EOF

# Set hostname because it's used for Consul and Nomad names
sudo hostnamectl set-hostname nomad-client
echo '127.0.1.1       nomad-client.unassigned-domain        nomad-client' | sudo tee -a /etc/hosts

# Start Nomad
sudo systemctl enable nomad
sudo systemctl start nomad

##-------------------------------------------------------------------
#write out current crontab
crontab -l > mycron
#echo new cron into cron file
echo "00 * * * * systemctl restart nomad" >> mycron
echo "30 * * * * systemctl restart nomad" >> mycron
#install new cron file
crontab mycron
rm mycron
